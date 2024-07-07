package tor

import (
	"bytes"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/textproto"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync/atomic"
)

const (
	// success is the Tor Control response code representing a successful
	// request.
	success = 250

	// invalidNumOfArguments is the Tor Control response code representing
	// there being an invalid number of arguments.
	invalidNumOfArguments = 512

	// serviceIDNotRecognized is the Tor Control response code representing
	// the specified ServiceID is not recognized.
	serviceIDNotRecognized = 552

	// nonceLen is the length of a nonce generated by either the controller
	// or the Tor server
	nonceLen = 32

	// cookieLen is the length of the authentication cookie.
	cookieLen = 32

	// ProtocolInfoVersion is the `protocolinfo` version currently supported
	// by the Tor server.
	ProtocolInfoVersion = 1

	// MinTorVersion is the minimum supported version that the Tor server
	// must be running on. This is needed in order to create v3 onion
	// services through Tor's control port.
	MinTorVersion = "0.3.3.6"

	// authSafeCookie is the name of the SAFECOOKIE authentication method.
	authSafeCookie = "SAFECOOKIE"

	// authHashedPassword is the name of the HASHEDPASSWORD authentication
	// method.
	authHashedPassword = "HASHEDPASSWORD"

	// authNull is the name of the NULL authentication method.
	authNull = "NULL"
)

var (
	// serverKey is the key used when computing the HMAC-SHA256 of a message
	// from the server.
	serverKey = []byte("Tor safe cookie authentication " +
		"server-to-controller hash")

	// controllerKey is the key used when computing the HMAC-SHA256 of a
	// message from the controller.
	controllerKey = []byte("Tor safe cookie authentication " +
		"controller-to-server hash")

	// errCodeNotMatch is used when an expected response code is not
	// returned.
	errCodeNotMatch = errors.New("unexpected code")

	// errTCNotStarted is used when we require the tor controller to be
	// started while it's not.
	errTCNotStarted = errors.New("tor controller must be started")

	// errTCNotStarted is used when we require the tor controller to be
	// not stopped while it is.
	errTCStopped = errors.New("tor controller must not be stopped")

	// replyFieldRegexp is the regular expression used to find fields in a
	// reply.  Parameters within a reply should be of the form KEY=VALUE or
	// KEY="VALUE", where quoted values might contain spaces, newlines and
	// quoted pairs. If the parameter doesn't contain "=", then we can
	// assume it doesn't provide any relevant information that isn't already
	// known. Read more on this topic:
	//   https://gitweb.torproject.org/torspec.git/tree/control-spec.txt#n188
	replyFieldRegexp = regexp.MustCompile(
		`[^" \r\n]+=(?:"(?:[^"\\]|\\[\0-\x7F])*"|[^" \r\n]*)`,
	)
)

// Controller is an implementation of the Tor Control protocol. This is used in
// order to communicate with a Tor server. Its only supported method of
// authentication is the SAFECOOKIE method.
//
// NOTE: The connection to the Tor server must be authenticated before
// proceeding to send commands. Otherwise, the connection will be closed.
//
// TODO:
//   - if adding support for more commands, extend this with a command queue?
//   - place under sub-package?
//   - support async replies from the server
type Controller struct {
	// started is used atomically in order to prevent multiple calls to
	// Start.
	started int32

	// stopped is used atomically in order to prevent multiple calls to
	// Stop.
	stopped int32

	// conn is the underlying connection between the controller and the
	// Tor server. It provides read and write methods to simplify the
	// text-based messages within the connection.
	conn *textproto.Conn

	// controlAddr is the host:port the Tor server is listening locally for
	// controller connections on.
	controlAddr string

	// password, if non-empty, signals that the controller should attempt to
	// authenticate itself with the backing Tor daemon through the
	// HASHEDPASSWORD authentication method with this value.
	password string

	// version is the current version of the Tor server.
	version string

	// targetIPAddress is the IP address which we tell the Tor server to use
	// to connect to the LND node.  This is required when the Tor server
	// runs on another host, otherwise the service will not be reachable.
	targetIPAddress string

	// activeServiceID is the Onion ServiceID created by ADD_ONION.
	activeServiceID string
}

// NewController returns a new Tor controller that will be able to interact with
// a Tor server.
func NewController(controlAddr string, targetIPAddress string,
	password string) *Controller {

	return &Controller{
		controlAddr:     controlAddr,
		targetIPAddress: targetIPAddress,
		password:        password,
	}
}

// Start establishes and authenticates the connection between the controller
// and a Tor server. Once done, the controller will be able to send commands
// and expect responses.
func (c *Controller) Start() error {
	if !atomic.CompareAndSwapInt32(&c.started, 0, 1) {
		return nil
	}

	log.Info("Starting tor controller")

	conn, err := textproto.Dial("tcp", c.controlAddr)
	if err != nil {
		return fmt.Errorf("unable to connect to Tor server: %w", err)
	}

	c.conn = conn

	return c.authenticate()
}

// Stop closes the connection between the controller and the Tor server.
func (c *Controller) Stop() error {
	if !atomic.CompareAndSwapInt32(&c.stopped, 0, 1) {
		return nil
	}

	log.Info("Stopping tor controller")

	// Remove the onion service.
	if err := c.DelOnion(c.activeServiceID); err != nil {
		log.Errorf("DEL_ONION got error: %v", err)
		return err
	}

	// Reset service ID.
	c.activeServiceID = ""

	return c.conn.Close()
}

// Reconnect makes a new socket connection between the tor controller and
// daemon. It will attempt to close the old connection, make a new connection
// and authenticate, and finally reset the activeServiceID that the controller
// is aware of.
//
// NOTE: Any old onion services will be removed once this function is called.
// In the case of a Tor daemon restart, previously created onion services will
// no longer be there. If the function is called without a Tor daemon restart,
// because the control connection is reset, all the onion services belonging to
// the old connection will be removed.
func (c *Controller) Reconnect() error {
	// Require the tor controller to be running when we want to reconnect.
	// This means the started flag must be 1 and the stopped flag must be
	// 0.
	if c.started != 1 {
		return errTCNotStarted
	}
	if c.stopped != 0 {
		return errTCStopped
	}

	log.Info("Re-connectting tor controller")

	// If we have an old connection, try to close it. We might receive an
	// error if the connection has already been closed by Tor daemon(ie,
	// daemon restarted), so we ignore the error here.
	if c.conn != nil {
		if err := c.conn.Close(); err != nil {
			log.Debugf("closing old conn got err: %v", err)
		}
	}

	// Make a new connection and authenticate.
	conn, err := textproto.Dial("tcp", c.controlAddr)
	if err != nil {
		return fmt.Errorf("unable to connect to Tor server: %w", err)
	}

	c.conn = conn

	// Authenticate the connection between the controller and Tor daemon.
	if err := c.authenticate(); err != nil {
		return err
	}

	// Reset the activeServiceID. This value would only be set if a
	// previous onion service was created. Because the old connection has
	// been closed at this point, the old onion service is no longer
	// active.
	c.activeServiceID = ""

	return nil
}

// sendCommand sends a command to the Tor server and returns its response, as a
// single space-delimited string, and code.
func (c *Controller) sendCommand(command string) (int, string, error) {
	id, err := c.conn.Cmd(command)
	if err != nil {
		return 0, "", err
	}

	// Make sure our reader only process the response returned from the
	// above command.
	c.conn.StartResponse(id)
	defer c.conn.EndResponse(id)

	code, reply, err := c.readResponse(success)
	if err != nil {
		log.Debugf("sendCommand:%s got err:%v, reply:%v",
			command, err, reply)
		return code, reply, err
	}

	return code, reply, nil
}

// readResponse reads the replies from Tor to the controller. The reply has the
// following format,
//
//	Reply = SyncReply / AsyncReply
//	SyncReply = *(MidReplyLine / DataReplyLine) EndReplyLine
//	AsyncReply = *(MidReplyLine / DataReplyLine) EndReplyLine
//
//	MidReplyLine = StatusCode "-" ReplyLine
//	DataReplyLine = StatusCode "+" ReplyLine CmdData
//	EndReplyLine = StatusCode SP ReplyLine
//	ReplyLine = [ReplyText] CRLF
//	ReplyText = XXXX
//	StatusCode = 3DIGIT
//
// Unless specified otherwise, multiple lines in a single reply from Tor daemon
// to the controller are guaranteed to share the same status code. Read more on
// this topic:
//
//	https://gitweb.torproject.org/torspec.git/tree/control-spec.txt#n158
//
// NOTE: this code is influenced by https://github.com/Yawning/bulb.
func (c *Controller) readResponse(expected int) (int, string, error) {
	// Clean the buffer inside the conn. This is needed when we encountered
	// an error while reading the response, the remaining lines need to be
	// cleaned before next read.
	defer func() {
		if _, err := c.conn.R.Discard(c.conn.R.Buffered()); err != nil {
			log.Errorf("clean read buffer failed: %v", err)
		}
	}()

	reply, code := "", 0
	hasMoreLines := true

	for hasMoreLines {
		line, err := c.conn.Reader.ReadLine()
		if err != nil {
			return 0, reply, err
		}
		log.Tracef("Reading line: %v", line)

		// Line being shortter than 4 is not allowed.
		if len(line) < 4 {
			err = textproto.ProtocolError("short line: " + line)
			return 0, reply, err
		}

		// Parse the status code.
		code, err = strconv.Atoi(line[0:3])
		if err != nil {
			return code, reply, err
		}

		switch line[3] {
		// EndReplyLine = StatusCode SP ReplyLine.
		// Example: 250 OK
		// This is the end of the response, so we mark hasMoreLines to
		// be false to exit the loop.
		case ' ':
			reply += line[4:]
			hasMoreLines = false

		// MidReplyLine = StatusCode "-" ReplyLine.
		// Example: 250-version=...
		// This is a continued response, so we keep reading the next
		// line.
		case '-':
			reply += line[4:]

		// DataReplyLine = StatusCode "+" ReplyLine CmdData.
		// Example: 250+config-text=
		//	    line1
		//	    line2
		//          more lines...
		//          .
		// This is a data response, meaning the following multiple
		// lines are the actual data, and a dot(.) in the end means the
		// end of the data response. The response will be formatted as,
		// 	key=line1,line2,...
		// The above example will then be,
		// 	config-text=line1,line2,...
		case '+':
			// Add the key(config-text=)
			reply += line[4:]

			// Add the values.
			resp, err := c.conn.Reader.ReadDotLines()
			if err != nil {
				return code, reply, err
			}
			reply += strings.Join(resp, ",")

		// Invalid line separator found.
		default:
			err = textproto.ProtocolError("invalid line: " + line)
			return code, reply, err
		}

		// We check the code here so that the error message is parsed
		// from the line.
		if code != expected {
			return code, reply, errCodeNotMatch
		}

		// Separate each line using "\n".
		if hasMoreLines {
			reply += "\n"
		}
	}

	log.Tracef("Parsed reply: %v", reply)
	return code, reply, nil
}

// unescapeValue removes escape codes from the value in the Tor reply. A
// backslash followed by any character represents that character, so we remove
// any backslash not preceded by another backslash.
func unescapeValue(value string) string {
	newString := ""
	justRemovedBackslash := false

	for _, char := range value {
		if char == '\\' && !justRemovedBackslash {
			justRemovedBackslash = true
			continue
		}

		newString += string(char)
		justRemovedBackslash = false
	}

	return newString
}

// parseTorReply parses the reply from the Tor server after receiving a command
// from a controller. This will parse the relevant reply parameters into a map
// of keys and values.
func parseTorReply(reply string) map[string]string {
	params := make(map[string]string)

	// Find all fields of a reply. The -1 indicates that we want this to
	// find all instances of the regexp.
	contents := replyFieldRegexp.FindAllString(reply, -1)
	for _, content := range contents {
		// Each parameter within the reply should be of the form
		// KEY=VALUE or KEY="VALUE".
		keyValue := strings.SplitN(content, "=", 2)
		key := keyValue[0]
		value := keyValue[1]

		// Quoted strings need extra processing.
		if strings.HasPrefix(value, `"`) {
			// Remove quotes around the value.
			value = value[1 : len(value)-1]

			// Unescape the value.
			value = unescapeValue(value)
		}

		params[key] = value
	}

	return params
}

// authenticate authenticates the connection between the controller and the
// Tor server using either of the following supported authentication methods
// depending on its configuration: SAFECOOKIE, HASHEDPASSWORD, and NULL.
func (c *Controller) authenticate() error {
	protocolInfo, err := c.protocolInfo()
	if err != nil {
		return err
	}

	log.Debugf("received protocol info: %v", protocolInfo)

	// With the version retrieved, we'll cache it now in case it needs to be
	// used later on.
	c.version = protocolInfo.version()

	switch {
	// If a password was provided, then we should attempt to use the
	// HASHEDPASSWORD authentication method.
	case c.password != "":
		if !protocolInfo.supportsAuthMethod(authHashedPassword) {
			return fmt.Errorf("%v authentication method not "+
				"supported", authHashedPassword)
		}

		return c.authenticateViaHashedPassword()

	// Otherwise, attempt to authentication via the SAFECOOKIE method as it
	// provides the most security.
	case protocolInfo.supportsAuthMethod(authSafeCookie):
		return c.authenticateViaSafeCookie(protocolInfo)

	// Fallback to the NULL method if any others aren't supported.
	case protocolInfo.supportsAuthMethod(authNull):
		return c.authenticateViaNull()

	// No supported authentication methods, fail.
	default:
		return errors.New("the Tor server must be configured with " +
			"NULL, SAFECOOKIE, or HASHEDPASSWORD authentication")
	}
}

// authenticateViaNull authenticates the controller with the Tor server using
// the NULL authentication method.
func (c *Controller) authenticateViaNull() error {
	_, _, err := c.sendCommand("AUTHENTICATE")
	return err
}

// authenticateViaHashedPassword authenticates the controller with the Tor
// server using the HASHEDPASSWORD authentication method.
func (c *Controller) authenticateViaHashedPassword() error {
	cmd := fmt.Sprintf("AUTHENTICATE \"%s\"", c.password)
	_, _, err := c.sendCommand(cmd)
	return err
}

// authenticateViaSafeCookie authenticates the controller with the Tor server
// using the SAFECOOKIE authentication method.
func (c *Controller) authenticateViaSafeCookie(info protocolInfo) error {
	// Before proceeding to authenticate the connection, we'll retrieve
	// the authentication cookie of the Tor server. This will be used
	// throughout the authentication routine. We do this before as once the
	// authentication routine has begun, it is not possible to retrieve it
	// mid-way.
	cookie, err := c.getAuthCookie(info)
	if err != nil {
		return fmt.Errorf("unable to retrieve authentication cookie: "+
			"%v", err)
	}

	// Authenticating using the SAFECOOKIE authentication method is a two
	// step process. We'll kick off the authentication routine by sending
	// the AUTHCHALLENGE command followed by a hex-encoded 32-byte nonce.
	clientNonce := make([]byte, nonceLen)
	if _, err := rand.Read(clientNonce); err != nil {
		return fmt.Errorf("unable to generate client nonce: %w", err)
	}

	cmd := fmt.Sprintf("AUTHCHALLENGE SAFECOOKIE %x", clientNonce)
	_, reply, err := c.sendCommand(cmd)
	if err != nil {
		return err
	}

	// If successful, the reply from the server should be of the following
	// format:
	//
	//	"250 AUTHCHALLENGE"
	//		SP "SERVERHASH=" ServerHash
	//		SP "SERVERNONCE=" ServerNonce
	//		CRLF
	//
	// We're interested in retrieving the SERVERHASH and SERVERNONCE
	// parameters, so we'll parse our reply to do so.
	replyParams := parseTorReply(reply)

	// Once retrieved, we'll ensure these values are of proper length when
	// decoded.
	serverHash, ok := replyParams["SERVERHASH"]
	if !ok {
		return errors.New("server hash not found in reply")
	}
	decodedServerHash, err := hex.DecodeString(serverHash)
	if err != nil {
		return fmt.Errorf("unable to decode server hash: %w", err)
	}
	if len(decodedServerHash) != sha256.Size {
		return errors.New("invalid server hash length")
	}

	serverNonce, ok := replyParams["SERVERNONCE"]
	if !ok {
		return errors.New("server nonce not found in reply")
	}
	decodedServerNonce, err := hex.DecodeString(serverNonce)
	if err != nil {
		return fmt.Errorf("unable to decode server nonce: %w", err)
	}
	if len(decodedServerNonce) != nonceLen {
		return errors.New("invalid server nonce length")
	}

	// The server hash above was constructed by computing the HMAC-SHA256
	// of the message composed of the cookie, client nonce, and server
	// nonce. We'll redo this computation ourselves to ensure the integrity
	// and authentication of the message.
	hmacMessage := bytes.Join(
		[][]byte{cookie, clientNonce, decodedServerNonce}, []byte{},
	)
	computedServerHash := computeHMAC256(serverKey, hmacMessage)
	if !hmac.Equal(computedServerHash, decodedServerHash) {
		return fmt.Errorf("expected server hash %x, got %x",
			decodedServerHash, computedServerHash)
	}

	// If the MAC check was successful, we'll proceed with the last step of
	// the authentication routine. We'll now send the AUTHENTICATE command
	// followed by a hex-encoded client hash constructed by computing the
	// HMAC-SHA256 of the same message, but this time using the controller's
	// key.
	clientHash := computeHMAC256(controllerKey, hmacMessage)
	if len(clientHash) != sha256.Size {
		return errors.New("invalid client hash length")
	}

	cmd = fmt.Sprintf("AUTHENTICATE %x", clientHash)
	if _, _, err := c.sendCommand(cmd); err != nil {
		return err
	}

	return nil
}

// getAuthCookie retrieves the authentication cookie in bytes from the Tor
// server. Cookie authentication must be enabled for this to work.
func (c *Controller) getAuthCookie(info protocolInfo) ([]byte, error) {
	// Retrieve the cookie file path from the PROTOCOLINFO reply.
	cookieFilePath, ok := info["COOKIEFILE"]
	if !ok {
		return nil, errors.New("COOKIEFILE not found in PROTOCOLINFO " +
			"reply")
	}
	cookieFilePath = strings.Trim(cookieFilePath, "\"")

	// Read the cookie from the file and ensure it has the correct length.
	cookie, err := os.ReadFile(cookieFilePath)
	if err != nil {
		return nil, err
	}

	if len(cookie) != cookieLen {
		return nil, errors.New("invalid authentication cookie length")
	}

	return cookie, nil
}

// computeHMAC256 computes the HMAC-SHA256 of a key and message.
func computeHMAC256(key, message []byte) []byte {
	mac := hmac.New(sha256.New, key)
	mac.Write(message)
	return mac.Sum(nil)
}

// supportsV3 is a helper function that parses the current version of the Tor
// server and determines whether it supports creating v3 onion services through
// Tor's control port. The version string should be of the format:
//
//	major.minor.revision.build
func supportsV3(version string) error {
	// We'll split the minimum Tor version that's supported and the given
	// version in order to individually compare each number.
	parts := strings.Split(version, ".")
	if len(parts) != 4 {
		return errors.New("version string is not of the format " +
			"major.minor.revision.build")
	}

	// It's possible that the build number (the last part of the version
	// string) includes a pre-release string, e.g. rc, beta, etc., so we'll
	// parse that as well.
	build := strings.Split(parts[len(parts)-1], "-")
	parts[len(parts)-1] = build[0]

	// Ensure that each part of the version string corresponds to a number.
	for _, part := range parts {
		if _, err := strconv.Atoi(part); err != nil {
			return err
		}
	}

	// Once we've determined we have a proper version string of the format
	// major.minor.revision.build, we can just do a string comparison to
	// determine if it satisfies the minimum version supported.
	if version < MinTorVersion {
		return fmt.Errorf("version %v below minimum version supported "+
			"%v", version, MinTorVersion)
	}

	return nil
}

// protocolInfo is encompasses the details of a response to a PROTOCOLINFO
// command.
type protocolInfo map[string]string

// version returns the Tor version as reported by the server.
func (i protocolInfo) version() string {
	version := i["Tor"]
	return strings.Trim(version, "\"")
}

// supportsAuthMethod determines whether the Tor server supports the given
// authentication method.
func (i protocolInfo) supportsAuthMethod(method string) bool {
	methods, ok := i["METHODS"]
	if !ok {
		return false
	}
	return strings.Contains(methods, method)
}

// protocolInfo sends a "PROTOCOLINFO" command to the Tor server and returns its
// response.
func (c *Controller) protocolInfo() (protocolInfo, error) {
	cmd := fmt.Sprintf("PROTOCOLINFO %d", ProtocolInfoVersion)
	_, reply, err := c.sendCommand(cmd)
	if err != nil {
		return nil, err
	}

	return protocolInfo(parseTorReply(reply)), nil
}
