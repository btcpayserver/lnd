package lnwire

import (
	"bytes"
	crand "crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"image/color"
	"io"
	"math"
	"math/rand"
	"net"
	"reflect"
	"testing"
	"testing/quick"
	"time"

	"github.com/btcsuite/btcd/btcec/v2"
	"github.com/btcsuite/btcd/btcec/v2/ecdsa"
	"github.com/btcsuite/btcd/btcutil"
	"github.com/btcsuite/btcd/chaincfg/chainhash"
	"github.com/btcsuite/btcd/wire"
	"github.com/lightningnetwork/lnd/fn"
	"github.com/lightningnetwork/lnd/lnwallet/chainfee"
	"github.com/lightningnetwork/lnd/tlv"
	"github.com/lightningnetwork/lnd/tor"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

var (
	shaHash1Bytes, _ = hex.DecodeString("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
	shaHash1, _      = chainhash.NewHash(shaHash1Bytes)
	outpoint1        = wire.NewOutPoint(shaHash1, 0)

	testRBytes, _ = hex.DecodeString("8ce2bc69281ce27da07e6683571319d18e949ddfa2965fb6caa1bf0314f882d7")
	testSBytes, _ = hex.DecodeString("299105481d63e0f4bc2a88121167221b6700d72a0ead154c03be696a292d24ae")
	testRScalar   = new(btcec.ModNScalar)
	testSScalar   = new(btcec.ModNScalar)
	_             = testRScalar.SetByteSlice(testRBytes)
	_             = testSScalar.SetByteSlice(testSBytes)
	testSig       = ecdsa.NewSignature(testRScalar, testSScalar)
)

const letterBytes = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

func randLocalNonce(r *rand.Rand) Musig2Nonce {
	var nonce Musig2Nonce
	_, _ = io.ReadFull(r, nonce[:])

	return nonce
}

func someLocalNonce[T tlv.TlvType](
	r *rand.Rand) tlv.OptionalRecordT[T, Musig2Nonce] {

	return tlv.SomeRecordT(tlv.NewRecordT[T, Musig2Nonce](
		randLocalNonce(r),
	))
}

func randPartialSig(r *rand.Rand) (*PartialSig, error) {
	var sigBytes [32]byte
	if _, err := r.Read(sigBytes[:]); err != nil {
		return nil, fmt.Errorf("unable to generate sig: %w", err)
	}

	var s btcec.ModNScalar
	s.SetByteSlice(sigBytes[:])

	return &PartialSig{
		Sig: s,
	}, nil
}

func somePartialSig(t *testing.T,
	r *rand.Rand) tlv.OptionalRecordT[PartialSigType, PartialSig] {

	sig, err := randPartialSig(r)
	if err != nil {
		t.Fatal(err)
	}

	return tlv.SomeRecordT(tlv.NewRecordT[PartialSigType, PartialSig](
		*sig,
	))
}

func randPartialSigWithNonce(r *rand.Rand) (*PartialSigWithNonce, error) {
	var sigBytes [32]byte
	if _, err := r.Read(sigBytes[:]); err != nil {
		return nil, fmt.Errorf("unable to generate sig: %w", err)
	}

	var s btcec.ModNScalar
	s.SetByteSlice(sigBytes[:])

	return &PartialSigWithNonce{
		PartialSig: NewPartialSig(s),
		Nonce:      randLocalNonce(r),
	}, nil
}

func somePartialSigWithNonce(t *testing.T,
	r *rand.Rand) OptPartialSigWithNonceTLV {

	sig, err := randPartialSigWithNonce(r)
	if err != nil {
		t.Fatal(err)
	}

	return tlv.SomeRecordT(
		tlv.NewRecordT[PartialSigWithNonceType, PartialSigWithNonce](
			*sig,
		),
	)
}

func randAlias(r *rand.Rand) NodeAlias {
	var a NodeAlias
	for i := range a {
		a[i] = letterBytes[r.Intn(len(letterBytes))]
	}

	return a
}

func randPubKey() (*btcec.PublicKey, error) {
	priv, err := btcec.NewPrivateKey()
	if err != nil {
		return nil, err
	}

	return priv.PubKey(), nil
}

// pubkeyFromHex parses a Bitcoin public key from a hex encoded string.
func pubkeyFromHex(keyHex string) (*btcec.PublicKey, error) {
	pubKeyBytes, err := hex.DecodeString(keyHex)
	if err != nil {
		return nil, err
	}

	return btcec.ParsePubKey(pubKeyBytes)
}

// generateRandomBytes returns a slice of n random bytes.
func generateRandomBytes(n int) ([]byte, error) {
	b := make([]byte, n)
	_, err := crand.Read(b)
	if err != nil {
		return nil, err
	}

	return b, nil
}

func randRawKey() ([33]byte, error) {
	var n [33]byte

	priv, err := btcec.NewPrivateKey()
	if err != nil {
		return n, err
	}

	copy(n[:], priv.PubKey().SerializeCompressed())

	return n, nil
}

func randDeliveryAddress(r *rand.Rand) (DeliveryAddress, error) {
	// Generate size minimum one. Empty scripts should be tested specifically.
	size := r.Intn(deliveryAddressMaxSize) + 1
	da := DeliveryAddress(make([]byte, size))

	_, err := r.Read(da)
	return da, err
}

func randRawFeatureVector(r *rand.Rand) *RawFeatureVector {
	featureVec := NewRawFeatureVector()
	for i := 0; i < 10000; i++ {
		if r.Int31n(2) == 0 {
			featureVec.Set(FeatureBit(i))
		}
	}
	return featureVec
}

func randTCP4Addr(r *rand.Rand) (*net.TCPAddr, error) {
	var ip [4]byte
	if _, err := r.Read(ip[:]); err != nil {
		return nil, err
	}

	var port [2]byte
	if _, err := r.Read(port[:]); err != nil {
		return nil, err
	}

	addrIP := net.IP(ip[:])
	addrPort := int(binary.BigEndian.Uint16(port[:]))

	return &net.TCPAddr{IP: addrIP, Port: addrPort}, nil
}

func randTCP6Addr(r *rand.Rand) (*net.TCPAddr, error) {
	var ip [16]byte
	if _, err := r.Read(ip[:]); err != nil {
		return nil, err
	}

	var port [2]byte
	if _, err := r.Read(port[:]); err != nil {
		return nil, err
	}

	addrIP := net.IP(ip[:])
	addrPort := int(binary.BigEndian.Uint16(port[:]))

	return &net.TCPAddr{IP: addrIP, Port: addrPort}, nil
}

func randV2OnionAddr(r *rand.Rand) (*tor.OnionAddr, error) {
	var serviceID [tor.V2DecodedLen]byte
	if _, err := r.Read(serviceID[:]); err != nil {
		return nil, err
	}

	var port [2]byte
	if _, err := r.Read(port[:]); err != nil {
		return nil, err
	}

	onionService := tor.Base32Encoding.EncodeToString(serviceID[:])
	onionService += tor.OnionSuffix
	addrPort := int(binary.BigEndian.Uint16(port[:]))

	return &tor.OnionAddr{OnionService: onionService, Port: addrPort}, nil
}

func randV3OnionAddr(r *rand.Rand) (*tor.OnionAddr, error) {
	var serviceID [tor.V3DecodedLen]byte
	if _, err := r.Read(serviceID[:]); err != nil {
		return nil, err
	}

	var port [2]byte
	if _, err := r.Read(port[:]); err != nil {
		return nil, err
	}

	onionService := tor.Base32Encoding.EncodeToString(serviceID[:])
	onionService += tor.OnionSuffix
	addrPort := int(binary.BigEndian.Uint16(port[:]))

	return &tor.OnionAddr{OnionService: onionService, Port: addrPort}, nil
}

func randOpaqueAddr(r *rand.Rand) (*OpaqueAddrs, error) {
	payloadLen := r.Int63n(64) + 1
	payload := make([]byte, payloadLen)

	// The first byte is the address type. So set it to one that we
	// definitely don't know about.
	payload[0] = math.MaxUint8

	// Generate random bytes for the rest of the payload.
	if _, err := r.Read(payload[1:]); err != nil {
		return nil, err
	}

	return &OpaqueAddrs{Payload: payload}, nil
}

func randAddrs(r *rand.Rand) ([]net.Addr, error) {
	tcp4Addr, err := randTCP4Addr(r)
	if err != nil {
		return nil, err
	}

	tcp6Addr, err := randTCP6Addr(r)
	if err != nil {
		return nil, err
	}

	v2OnionAddr, err := randV2OnionAddr(r)
	if err != nil {
		return nil, err
	}

	v3OnionAddr, err := randV3OnionAddr(r)
	if err != nil {
		return nil, err
	}

	opaqueAddrs, err := randOpaqueAddr(r)
	if err != nil {
		return nil, err
	}

	return []net.Addr{
		tcp4Addr, tcp6Addr, v2OnionAddr, v3OnionAddr, opaqueAddrs,
	}, nil
}

// TestChanUpdateChanFlags ensures that converting the ChanUpdateChanFlags and
// ChanUpdateMsgFlags bitfields to a string behaves as expected.
func TestChanUpdateChanFlags(t *testing.T) {
	t.Parallel()

	testCases := []struct {
		flags    uint8
		expected string
	}{
		{
			flags:    0,
			expected: "00000000",
		},
		{
			flags:    1,
			expected: "00000001",
		},
		{
			flags:    3,
			expected: "00000011",
		},
		{
			flags:    255,
			expected: "11111111",
		},
	}

	for _, test := range testCases {
		chanFlag := ChanUpdateChanFlags(test.flags)
		toStr := chanFlag.String()
		if toStr != test.expected {
			t.Fatalf("expected %v, got %v",
				test.expected, toStr)
		}

		msgFlag := ChanUpdateMsgFlags(test.flags)
		toStr = msgFlag.String()
		if toStr != test.expected {
			t.Fatalf("expected %v, got %v",
				test.expected, toStr)
		}
	}
}

// TestDecodeUnknownAddressType shows that an unknown address type is currently
// incorrectly dealt with.
func TestDecodeUnknownAddressType(t *testing.T) {
	// Add a normal, clearnet address.
	tcpAddr := &net.TCPAddr{
		IP:   net.IP{127, 0, 0, 1},
		Port: 8080,
	}

	// Add an onion address.
	onionAddr := &tor.OnionAddr{
		OnionService: "abcdefghijklmnop.onion",
		Port:         9065,
	}

	// Now add an address with an unknown type.
	var newAddrType addressType = math.MaxUint8
	data := make([]byte, 0, 16)
	data = append(data, uint8(newAddrType))
	opaqueAddrs := &OpaqueAddrs{
		Payload: data,
	}

	buffer := bytes.NewBuffer(make([]byte, 0, MaxMsgBody))
	err := WriteNetAddrs(
		buffer, []net.Addr{tcpAddr, onionAddr, opaqueAddrs},
	)
	require.NoError(t, err)

	// Now we attempt to parse the bytes and assert that we get an error.
	var addrs []net.Addr
	err = ReadElement(buffer, &addrs)
	require.NoError(t, err)
	require.Len(t, addrs, 3)
	require.Equal(t, tcpAddr.String(), addrs[0].String())
	require.Equal(t, onionAddr.String(), addrs[1].String())
	require.Equal(t, hex.EncodeToString(data), addrs[2].String())
}

func TestMaxOutPointIndex(t *testing.T) {
	t.Parallel()

	op := wire.OutPoint{
		Index: math.MaxUint32,
	}

	var b bytes.Buffer
	if err := WriteOutPoint(&b, op); err == nil {
		t.Fatalf("write of outPoint should fail, index exceeds 16-bits")
	}
}

func TestEmptyMessageUnknownType(t *testing.T) {
	t.Parallel()

	fakeType := CustomTypeStart - 1
	if _, err := makeEmptyMessage(fakeType); err == nil {
		t.Fatalf("should not be able to make an empty message of an " +
			"unknown type")
	}
}

// randCustomRecords generates a random set of custom records for testing.
func randCustomRecords(t *testing.T, r *rand.Rand) CustomRecords {
	var (
		customRecords = CustomRecords{}

		// We'll generate a random number of records, between 1 and 10.
		numRecords = r.Intn(9) + 1
	)

	// For each record, we'll generate a random key and value.
	for i := 0; i < numRecords; i++ {
		// Keys must be equal to or greater than
		// MinCustomRecordsTlvType.
		keyOffset := uint64(r.Intn(100))
		key := MinCustomRecordsTlvType + keyOffset

		// Values are byte slices of any length.
		value := make([]byte, r.Intn(10))
		_, err := r.Read(value)
		require.NoError(t, err)

		customRecords[key] = value
	}

	// Validate the custom records as a sanity check.
	err := customRecords.Validate()
	require.NoError(t, err)

	return customRecords
}

// TestLightningWireProtocol uses the testing/quick package to create a series
// of fuzz tests to attempt to break a primary scenario which is implemented as
// property based testing scenario.
func TestLightningWireProtocol(t *testing.T) {
	t.Parallel()

	// mainScenario is the primary test that will programmatically be
	// executed for all registered wire messages. The quick-checker within
	// testing/quick will attempt to find an input to this function, s.t
	// the function returns false, if so then we've found an input that
	// violates our model of the system.
	mainScenario := func(msg Message) bool {
		// Give a new message, we'll serialize the message into a new
		// bytes buffer.
		var b bytes.Buffer
		if _, err := WriteMessage(&b, msg, 0); err != nil {
			t.Fatalf("unable to write msg: %v", err)
			return false
		}

		// Next, we'll ensure that the serialized payload (subtracting
		// the 2 bytes for the message type) is _below_ the specified
		// max payload size for this message.
		payloadLen := uint32(b.Len()) - 2
		if payloadLen > MaxMsgBody {
			t.Fatalf("msg payload constraint violated: %v > %v",
				payloadLen, MaxMsgBody)
			return false
		}

		// Finally, we'll deserialize the message from the written
		// buffer, and finally assert that the messages are equal.
		newMsg, err := ReadMessage(&b, 0)
		if err != nil {
			t.Fatalf("unable to read msg: %v", err)
			return false
		}
		if !assert.Equalf(t, msg, newMsg, "message mismatch") {
			return false
		}

		return true
	}

	// customTypeGen is a map of functions that are able to randomly
	// generate a given type. These functions are needed for types which
	// are too complex for the testing/quick package to automatically
	// generate.
	customTypeGen := map[MessageType]func([]reflect.Value, *rand.Rand){
		MsgStfu: func(v []reflect.Value, r *rand.Rand) {
			req := Stfu{}
			if _, err := r.Read(req.ChanID[:]); err != nil {
				t.Fatalf("unable to generate ChanID: %v", err)
			}

			// 1/2 chance of being initiator
			req.Initiator = r.Intn(2) == 1

			// 1/2 chance additional TLV data.
			if r.Intn(2) == 0 {
				req.ExtraData = []byte{0xfd, 0x00, 0xff, 0x00}
			}

			v[0] = reflect.ValueOf(req)
		},
		MsgInit: func(v []reflect.Value, r *rand.Rand) {
			req := NewInitMessage(
				randRawFeatureVector(r),
				randRawFeatureVector(r),
			)

			v[0] = reflect.ValueOf(*req)
		},
		MsgOpenChannel: func(v []reflect.Value, r *rand.Rand) {
			req := OpenChannel{
				FundingAmount:    btcutil.Amount(r.Int63()),
				PushAmount:       MilliSatoshi(r.Int63()),
				DustLimit:        btcutil.Amount(r.Int63()),
				MaxValueInFlight: MilliSatoshi(r.Int63()),
				ChannelReserve:   btcutil.Amount(r.Int63()),
				HtlcMinimum:      MilliSatoshi(r.Int31()),
				FeePerKiloWeight: uint32(r.Int63()),
				CsvDelay:         uint16(r.Int31()),
				MaxAcceptedHTLCs: uint16(r.Int31()),
				ChannelFlags:     FundingFlag(uint8(r.Int31())),
			}

			if _, err := r.Read(req.ChainHash[:]); err != nil {
				t.Fatalf("unable to generate chain hash: %v", err)
				return
			}

			if _, err := r.Read(req.PendingChannelID[:]); err != nil {
				t.Fatalf("unable to generate pending chan id: %v", err)
				return
			}

			var err error
			req.FundingKey, err = randPubKey()
			if err != nil {
				t.Fatalf("unable to generate key: %v", err)
				return
			}
			req.RevocationPoint, err = randPubKey()
			if err != nil {
				t.Fatalf("unable to generate key: %v", err)
				return
			}
			req.PaymentPoint, err = randPubKey()
			if err != nil {
				t.Fatalf("unable to generate key: %v", err)
				return
			}
			req.DelayedPaymentPoint, err = randPubKey()
			if err != nil {
				t.Fatalf("unable to generate key: %v", err)
				return
			}
			req.HtlcPoint, err = randPubKey()
			if err != nil {
				t.Fatalf("unable to generate key: %v", err)
				return
			}
			req.FirstCommitmentPoint, err = randPubKey()
			if err != nil {
				t.Fatalf("unable to generate key: %v", err)
				return
			}

			// 1/2 chance empty TLV records.
			if r.Intn(2) == 0 {
				req.UpfrontShutdownScript, err = randDeliveryAddress(r)
				if err != nil {
					t.Fatalf("unable to generate delivery address: %v", err)
					return
				}

				req.ChannelType = new(ChannelType)
				*req.ChannelType = ChannelType(*randRawFeatureVector(r))

				req.LeaseExpiry = new(LeaseExpiry)
				*req.LeaseExpiry = LeaseExpiry(1337)

				//nolint:lll
				req.LocalNonce = someLocalNonce[NonceRecordTypeT](r)
			} else {
				req.UpfrontShutdownScript = []byte{}
			}

			// 1/2 chance additional TLV data.
			if r.Intn(2) == 0 {
				req.ExtraData = []byte{0xfd, 0x00, 0xff, 0x00}
			}

			v[0] = reflect.ValueOf(req)
		},
		MsgAcceptChannel: func(v []reflect.Value, r *rand.Rand) {
			req := AcceptChannel{
				DustLimit:        btcutil.Amount(r.Int63()),
				MaxValueInFlight: MilliSatoshi(r.Int63()),
				ChannelReserve:   btcutil.Amount(r.Int63()),
				MinAcceptDepth:   uint32(r.Int31()),
				HtlcMinimum:      MilliSatoshi(r.Int31()),
				CsvDelay:         uint16(r.Int31()),
				MaxAcceptedHTLCs: uint16(r.Int31()),
			}

			if _, err := r.Read(req.PendingChannelID[:]); err != nil {
				t.Fatalf("unable to generate pending chan id: %v", err)
				return
			}

			var err error
			req.FundingKey, err = randPubKey()
			if err != nil {
				t.Fatalf("unable to generate key: %v", err)
				return
			}
			req.RevocationPoint, err = randPubKey()
			if err != nil {
				t.Fatalf("unable to generate key: %v", err)
				return
			}
			req.PaymentPoint, err = randPubKey()
			if err != nil {
				t.Fatalf("unable to generate key: %v", err)
				return
			}
			req.DelayedPaymentPoint, err = randPubKey()
			if err != nil {
				t.Fatalf("unable to generate key: %v", err)
				return
			}
			req.HtlcPoint, err = randPubKey()
			if err != nil {
				t.Fatalf("unable to generate key: %v", err)
				return
			}
			req.FirstCommitmentPoint, err = randPubKey()
			if err != nil {
				t.Fatalf("unable to generate key: %v", err)
				return
			}

			// 1/2 chance empty TLV records.
			if r.Intn(2) == 0 {
				req.UpfrontShutdownScript, err = randDeliveryAddress(r)
				if err != nil {
					t.Fatalf("unable to generate delivery address: %v", err)
					return
				}

				req.ChannelType = new(ChannelType)
				*req.ChannelType = ChannelType(*randRawFeatureVector(r))

				req.LeaseExpiry = new(LeaseExpiry)
				*req.LeaseExpiry = LeaseExpiry(1337)

				//nolint:lll
				req.LocalNonce = someLocalNonce[NonceRecordTypeT](r)
			} else {
				req.UpfrontShutdownScript = []byte{}
			}

			// 1/2 chance additional TLV data.
			if r.Intn(2) == 0 {
				req.ExtraData = []byte{0xfd, 0x00, 0xff, 0x00}
			}

			v[0] = reflect.ValueOf(req)
		},
		MsgFundingCreated: func(v []reflect.Value, r *rand.Rand) {
			req := FundingCreated{
				ExtraData: make([]byte, 0),
			}

			if _, err := r.Read(req.PendingChannelID[:]); err != nil {
				t.Fatalf("unable to generate pending chan id: %v", err)
				return
			}

			if _, err := r.Read(req.FundingPoint.Hash[:]); err != nil {
				t.Fatalf("unable to generate hash: %v", err)
				return
			}
			req.FundingPoint.Index = uint32(r.Int31()) % math.MaxUint16

			var err error
			req.CommitSig, err = NewSigFromSignature(testSig)
			if err != nil {
				t.Fatalf("unable to parse sig: %v", err)
				return
			}

			// 1/2 chance to attach a partial sig.
			if r.Intn(2) == 0 {
				req.PartialSig = somePartialSigWithNonce(t, r)
			}

			v[0] = reflect.ValueOf(req)
		},
		MsgFundingSigned: func(v []reflect.Value, r *rand.Rand) {
			var c [32]byte
			_, err := r.Read(c[:])
			if err != nil {
				t.Fatalf("unable to generate chan id: %v", err)
				return
			}

			req := FundingSigned{
				ChanID:    ChannelID(c),
				ExtraData: make([]byte, 0),
			}
			req.CommitSig, err = NewSigFromSignature(testSig)
			if err != nil {
				t.Fatalf("unable to parse sig: %v", err)
				return
			}

			// 1/2 chance to attach a partial sig.
			if r.Intn(2) == 0 {
				req.PartialSig = somePartialSigWithNonce(t, r)
			}

			v[0] = reflect.ValueOf(req)
		},
		MsgChannelReady: func(v []reflect.Value, r *rand.Rand) {
			var c [32]byte
			if _, err := r.Read(c[:]); err != nil {
				t.Fatalf("unable to generate chan id: %v", err)
				return
			}

			pubKey, err := randPubKey()
			if err != nil {
				t.Fatalf("unable to generate key: %v", err)
				return
			}

			req := NewChannelReady(ChannelID(c), pubKey)

			if r.Int31()%2 == 0 {
				scid := NewShortChanIDFromInt(uint64(r.Int63()))
				req.AliasScid = &scid

				//nolint:lll
				req.NextLocalNonce = someLocalNonce[NonceRecordTypeT](r)
			}

			v[0] = reflect.ValueOf(*req)
		},
		MsgShutdown: func(v []reflect.Value, r *rand.Rand) {
			var c [32]byte
			_, err := r.Read(c[:])
			if err != nil {
				t.Fatalf("unable to generate chan id: %v", err)
				return
			}

			shutdownAddr, err := randDeliveryAddress(r)
			if err != nil {
				t.Fatalf("unable to generate delivery "+
					"address: %v", err)
				return
			}

			req := Shutdown{
				ChannelID: ChannelID(c),
				Address:   shutdownAddr,
			}

			if r.Int31()%2 == 0 {
				//nolint:lll
				req.ShutdownNonce = someLocalNonce[ShutdownNonceType](r)
			}

			v[0] = reflect.ValueOf(req)
		},
		MsgClosingSigned: func(v []reflect.Value, r *rand.Rand) {
			req := ClosingSigned{
				FeeSatoshis: btcutil.Amount(r.Int63()),
				ExtraData:   make([]byte, 0),
			}
			var err error
			req.Signature, err = NewSigFromSignature(testSig)
			if err != nil {
				t.Fatalf("unable to parse sig: %v", err)
				return
			}

			if _, err := r.Read(req.ChannelID[:]); err != nil {
				t.Fatalf("unable to generate chan id: %v", err)
				return
			}

			if r.Int31()%2 == 0 {
				req.PartialSig = somePartialSig(t, r)
			}

			v[0] = reflect.ValueOf(req)
		},
		MsgDynPropose: func(v []reflect.Value, r *rand.Rand) {
			var dp DynPropose
			rand.Read(dp.ChanID[:])

			if rand.Uint32()%2 == 0 {
				v := btcutil.Amount(rand.Uint32())
				dp.DustLimit = fn.Some(v)
			}

			if rand.Uint32()%2 == 0 {
				v := MilliSatoshi(rand.Uint32())
				dp.MaxValueInFlight = fn.Some(v)
			}

			if rand.Uint32()%2 == 0 {
				v := btcutil.Amount(rand.Uint32())
				dp.ChannelReserve = fn.Some(v)
			}

			if rand.Uint32()%2 == 0 {
				v := uint16(rand.Uint32())
				dp.CsvDelay = fn.Some(v)
			}

			if rand.Uint32()%2 == 0 {
				v := uint16(rand.Uint32())
				dp.MaxAcceptedHTLCs = fn.Some(v)
			}

			if rand.Uint32()%2 == 0 {
				v, _ := btcec.NewPrivateKey()
				dp.FundingKey = fn.Some(*v.PubKey())
			}

			if rand.Uint32()%2 == 0 {
				v := ChannelType(*NewRawFeatureVector())
				dp.ChannelType = fn.Some(v)
			}

			if rand.Uint32()%2 == 0 {
				v := chainfee.SatPerKWeight(rand.Uint32())
				dp.KickoffFeerate = fn.Some(v)
			}

			v[0] = reflect.ValueOf(dp)
		},
		MsgDynReject: func(v []reflect.Value, r *rand.Rand) {
			var dr DynReject
			rand.Read(dr.ChanID[:])

			features := NewRawFeatureVector()
			if rand.Uint32()%2 == 0 {
				features.Set(FeatureBit(DPDustLimitSatoshis))
			}

			if rand.Uint32()%2 == 0 {
				features.Set(
					FeatureBit(DPMaxHtlcValueInFlightMsat),
				)
			}

			if rand.Uint32()%2 == 0 {
				features.Set(
					FeatureBit(DPChannelReserveSatoshis),
				)
			}

			if rand.Uint32()%2 == 0 {
				features.Set(FeatureBit(DPToSelfDelay))
			}

			if rand.Uint32()%2 == 0 {
				features.Set(FeatureBit(DPMaxAcceptedHtlcs))
			}

			if rand.Uint32()%2 == 0 {
				features.Set(FeatureBit(DPFundingPubkey))
			}

			if rand.Uint32()%2 == 0 {
				features.Set(FeatureBit(DPChannelType))
			}

			if rand.Uint32()%2 == 0 {
				features.Set(FeatureBit(DPKickoffFeerate))
			}
			dr.UpdateRejections = *features

			v[0] = reflect.ValueOf(dr)
		},
		MsgDynAck: func(v []reflect.Value, r *rand.Rand) {
			var da DynAck

			rand.Read(da.ChanID[:])
			if rand.Uint32()%2 == 0 {
				var nonce Musig2Nonce
				rand.Read(nonce[:])
				da.LocalNonce = fn.Some(nonce)
			}

			v[0] = reflect.ValueOf(da)
		},
		MsgKickoffSig: func(v []reflect.Value, r *rand.Rand) {
			ks := KickoffSig{
				ExtraData: make([]byte, 0),
			}

			rand.Read(ks.ChanID[:])
			rand.Read(ks.Signature.bytes[:])

			v[0] = reflect.ValueOf(ks)
		},
		MsgCommitSig: func(v []reflect.Value, r *rand.Rand) {
			req := NewCommitSig()
			if _, err := r.Read(req.ChanID[:]); err != nil {
				t.Fatalf("unable to generate chan id: %v", err)
				return
			}

			var err error
			req.CommitSig, err = NewSigFromSignature(testSig)
			if err != nil {
				t.Fatalf("unable to parse sig: %v", err)
				return
			}

			// Only create the slice if there will be any signatures
			// in it to prevent false positive test failures due to
			// an empty slice versus a nil slice.
			numSigs := uint16(r.Int31n(500))
			if numSigs > 0 {
				req.HtlcSigs = make([]Sig, numSigs)
			}
			for i := 0; i < int(numSigs); i++ {
				req.HtlcSigs[i], err = NewSigFromSignature(
					testSig,
				)
				if err != nil {
					t.Fatalf("unable to parse sig: %v", err)
					return
				}
			}

			req.CustomRecords = randCustomRecords(t, r)

			// 50/50 chance to attach a partial sig.
			if r.Int31()%2 == 0 {
				req.PartialSig = somePartialSigWithNonce(t, r)
			}

			v[0] = reflect.ValueOf(*req)
		},
		MsgRevokeAndAck: func(v []reflect.Value, r *rand.Rand) {
			req := NewRevokeAndAck()
			if _, err := r.Read(req.ChanID[:]); err != nil {
				t.Fatalf("unable to generate chan id: %v", err)
				return
			}
			if _, err := r.Read(req.Revocation[:]); err != nil {
				t.Fatalf("unable to generate bytes: %v", err)
				return
			}
			var err error
			req.NextRevocationKey, err = randPubKey()
			if err != nil {
				t.Fatalf("unable to generate key: %v", err)
				return
			}

			// 50/50 chance to attach a local nonce.
			if r.Int31()%2 == 0 {
				//nolint:lll
				req.LocalNonce = someLocalNonce[NonceRecordTypeT](r)
			}

			v[0] = reflect.ValueOf(*req)
		},
		MsgChannelAnnouncement: func(v []reflect.Value, r *rand.Rand) {
			var err error
			req := ChannelAnnouncement{
				ShortChannelID:  NewShortChanIDFromInt(uint64(r.Int63())),
				Features:        randRawFeatureVector(r),
				ExtraOpaqueData: make([]byte, 0),
			}
			req.NodeSig1, err = NewSigFromSignature(testSig)
			if err != nil {
				t.Fatalf("unable to parse sig: %v", err)
				return
			}
			req.NodeSig2, err = NewSigFromSignature(testSig)
			if err != nil {
				t.Fatalf("unable to parse sig: %v", err)
				return
			}
			req.BitcoinSig1, err = NewSigFromSignature(testSig)
			if err != nil {
				t.Fatalf("unable to parse sig: %v", err)
				return
			}
			req.BitcoinSig2, err = NewSigFromSignature(testSig)
			if err != nil {
				t.Fatalf("unable to parse sig: %v", err)
				return
			}

			req.NodeID1, err = randRawKey()
			if err != nil {
				t.Fatalf("unable to generate key: %v", err)
				return
			}
			req.NodeID2, err = randRawKey()
			if err != nil {
				t.Fatalf("unable to generate key: %v", err)
				return
			}
			req.BitcoinKey1, err = randRawKey()
			if err != nil {
				t.Fatalf("unable to generate key: %v", err)
				return
			}
			req.BitcoinKey2, err = randRawKey()
			if err != nil {
				t.Fatalf("unable to generate key: %v", err)
				return
			}
			if _, err := r.Read(req.ChainHash[:]); err != nil {
				t.Fatalf("unable to generate chain hash: %v", err)
				return
			}

			numExtraBytes := r.Int31n(1000)
			if numExtraBytes > 0 {
				req.ExtraOpaqueData = make([]byte, numExtraBytes)
				_, err := r.Read(req.ExtraOpaqueData[:])
				if err != nil {
					t.Fatalf("unable to generate opaque "+
						"bytes: %v", err)
					return
				}
			}

			v[0] = reflect.ValueOf(req)
		},
		MsgNodeAnnouncement: func(v []reflect.Value, r *rand.Rand) {
			var err error
			req := NodeAnnouncement{
				Features:  randRawFeatureVector(r),
				Timestamp: uint32(r.Int31()),
				Alias:     randAlias(r),
				RGBColor: color.RGBA{
					R: uint8(r.Int31()),
					G: uint8(r.Int31()),
					B: uint8(r.Int31()),
				},
				ExtraOpaqueData: make([]byte, 0),
			}
			req.Signature, err = NewSigFromSignature(testSig)
			if err != nil {
				t.Fatalf("unable to parse sig: %v", err)
				return
			}

			req.NodeID, err = randRawKey()
			if err != nil {
				t.Fatalf("unable to generate key: %v", err)
				return
			}

			req.Addresses, err = randAddrs(r)
			if err != nil {
				t.Fatalf("unable to generate addresses: %v", err)
			}

			numExtraBytes := r.Int31n(1000)
			if numExtraBytes > 0 {
				req.ExtraOpaqueData = make([]byte, numExtraBytes)
				_, err := r.Read(req.ExtraOpaqueData[:])
				if err != nil {
					t.Fatalf("unable to generate opaque "+
						"bytes: %v", err)
					return
				}
			}

			v[0] = reflect.ValueOf(req)
		},
		MsgChannelUpdate: func(v []reflect.Value, r *rand.Rand) {
			var err error

			msgFlags := ChanUpdateMsgFlags(r.Int31())
			maxHtlc := MilliSatoshi(r.Int63())

			// We make the max_htlc field zero if it is not flagged
			// as being part of the ChannelUpdate, to pass
			// serialization tests, as it will be ignored if the bit
			// is not set.
			if msgFlags&ChanUpdateRequiredMaxHtlc == 0 {
				maxHtlc = 0
			}

			req := ChannelUpdate{
				ShortChannelID:  NewShortChanIDFromInt(uint64(r.Int63())),
				Timestamp:       uint32(r.Int31()),
				MessageFlags:    msgFlags,
				ChannelFlags:    ChanUpdateChanFlags(r.Int31()),
				TimeLockDelta:   uint16(r.Int31()),
				HtlcMinimumMsat: MilliSatoshi(r.Int63()),
				HtlcMaximumMsat: maxHtlc,
				BaseFee:         uint32(r.Int31()),
				FeeRate:         uint32(r.Int31()),
				ExtraOpaqueData: make([]byte, 0),
			}
			req.Signature, err = NewSigFromSignature(testSig)
			if err != nil {
				t.Fatalf("unable to parse sig: %v", err)
				return
			}

			if _, err := r.Read(req.ChainHash[:]); err != nil {
				t.Fatalf("unable to generate chain hash: %v", err)
				return
			}

			numExtraBytes := r.Int31n(1000)
			if numExtraBytes > 0 {
				req.ExtraOpaqueData = make([]byte, numExtraBytes)
				_, err := r.Read(req.ExtraOpaqueData[:])
				if err != nil {
					t.Fatalf("unable to generate opaque "+
						"bytes: %v", err)
					return
				}
			}

			v[0] = reflect.ValueOf(req)
		},
		MsgAnnounceSignatures: func(v []reflect.Value, r *rand.Rand) {
			var err error
			req := AnnounceSignatures{
				ShortChannelID:  NewShortChanIDFromInt(uint64(r.Int63())),
				ExtraOpaqueData: make([]byte, 0),
			}

			req.NodeSignature, err = NewSigFromSignature(testSig)
			if err != nil {
				t.Fatalf("unable to parse sig: %v", err)
				return
			}

			req.BitcoinSignature, err = NewSigFromSignature(testSig)
			if err != nil {
				t.Fatalf("unable to parse sig: %v", err)
				return
			}

			if _, err := r.Read(req.ChannelID[:]); err != nil {
				t.Fatalf("unable to generate chan id: %v", err)
				return
			}

			numExtraBytes := r.Int31n(1000)
			if numExtraBytes > 0 {
				req.ExtraOpaqueData = make([]byte, numExtraBytes)
				_, err := r.Read(req.ExtraOpaqueData[:])
				if err != nil {
					t.Fatalf("unable to generate opaque "+
						"bytes: %v", err)
					return
				}
			}

			v[0] = reflect.ValueOf(req)
		},
		MsgChannelReestablish: func(v []reflect.Value, r *rand.Rand) {
			req := ChannelReestablish{
				NextLocalCommitHeight:  uint64(r.Int63()),
				RemoteCommitTailHeight: uint64(r.Int63()),
				ExtraData:              make([]byte, 0),
			}

			// With a 50/50 probability, we'll include the
			// additional fields so we can test our ability to
			// properly parse, and write out the optional fields.
			if r.Int()%2 == 0 {
				_, err := r.Read(req.LastRemoteCommitSecret[:])
				if err != nil {
					t.Fatalf("unable to read commit secret: %v", err)
					return
				}

				req.LocalUnrevokedCommitPoint, err = randPubKey()
				if err != nil {
					t.Fatalf("unable to generate key: %v", err)
					return
				}

				//nolint:lll
				req.LocalNonce = someLocalNonce[NonceRecordTypeT](r)
			}

			v[0] = reflect.ValueOf(req)
		},
		MsgQueryShortChanIDs: func(v []reflect.Value, r *rand.Rand) {
			req := QueryShortChanIDs{
				ExtraData: make([]byte, 0),
			}

			// With a 50/50 change, we'll either use zlib encoding,
			// or regular encoding.
			if r.Int31()%2 == 0 {
				req.EncodingType = EncodingSortedZlib
			} else {
				req.EncodingType = EncodingSortedPlain
			}

			if _, err := rand.Read(req.ChainHash[:]); err != nil {
				t.Fatalf("unable to read chain hash: %v", err)
				return
			}

			numChanIDs := rand.Int31n(5000)
			for i := int32(0); i < numChanIDs; i++ {
				req.ShortChanIDs = append(req.ShortChanIDs,
					NewShortChanIDFromInt(uint64(r.Int63())))
			}

			v[0] = reflect.ValueOf(req)
		},
		MsgReplyChannelRange: func(v []reflect.Value, r *rand.Rand) {
			req := ReplyChannelRange{
				FirstBlockHeight: uint32(r.Int31()),
				NumBlocks:        uint32(r.Int31()),
				ExtraData:        make([]byte, 0),
			}

			if _, err := rand.Read(req.ChainHash[:]); err != nil {
				t.Fatalf("unable to read chain hash: %v", err)
				return
			}

			req.Complete = uint8(r.Int31n(2))

			// With a 50/50 change, we'll either use zlib encoding,
			// or regular encoding.
			if r.Int31()%2 == 0 {
				req.EncodingType = EncodingSortedZlib
			} else {
				req.EncodingType = EncodingSortedPlain
			}

			numChanIDs := rand.Int31n(4000)
			for i := int32(0); i < numChanIDs; i++ {
				req.ShortChanIDs = append(req.ShortChanIDs,
					NewShortChanIDFromInt(uint64(r.Int63())))
			}

			// With a 50/50 chance, add some timestamps.
			if r.Int31()%2 == 0 {
				for i := int32(0); i < numChanIDs; i++ {
					timestamps := ChanUpdateTimestamps{
						Timestamp1: rand.Uint32(),
						Timestamp2: rand.Uint32(),
					}
					req.Timestamps = append(
						req.Timestamps, timestamps,
					)
				}
			}

			v[0] = reflect.ValueOf(req)
		},
		MsgQueryChannelRange: func(v []reflect.Value, r *rand.Rand) {
			req := QueryChannelRange{
				FirstBlockHeight: uint32(r.Int31()),
				NumBlocks:        uint32(r.Int31()),
				ExtraData:        make([]byte, 0),
			}

			_, err := rand.Read(req.ChainHash[:])
			require.NoError(t, err)

			// With a 50/50 change, we'll set a query option.
			if r.Int31()%2 == 0 {
				req.QueryOptions = NewTimestampQueryOption()
			}

			v[0] = reflect.ValueOf(req)
		},
		MsgPing: func(v []reflect.Value, r *rand.Rand) {
			// We use a special message generator here to ensure we
			// don't generate ping messages that are too large,
			// which'll cause the test to fail.
			//
			// We'll allow the test to generate padding bytes up to
			// the max message limit, factoring in the 2 bytes for
			// the num pong bytes and 2 bytes for encoding the
			// length of the padding bytes.
			paddingBytes := make([]byte, rand.Intn(MaxMsgBody-3))
			req := Ping{
				NumPongBytes: uint16(r.Intn(MaxPongBytes + 1)),
				PaddingBytes: paddingBytes,
			}

			v[0] = reflect.ValueOf(req)
		},
		MsgClosingComplete: func(v []reflect.Value, r *rand.Rand) {
			var c [32]byte
			_, err := r.Read(c[:])
			if err != nil {
				t.Fatalf("unable to generate chan id: %v",
					err)
				return
			}

			req := ClosingComplete{
				ChannelID:   ChannelID(c),
				FeeSatoshis: btcutil.Amount(r.Int63()),
				Sequence:    uint32(r.Int63()),
				ClosingSigs: ClosingSigs{},
			}

			if r.Intn(2) == 0 {
				sig := req.CloserNoClosee.Zero()
				_, err := r.Read(sig.Val.bytes[:])
				if err != nil {
					t.Fatalf("unable to generate sig: %v",
						err)
					return
				}

				req.CloserNoClosee = tlv.SomeRecordT(sig)
			}
			if r.Intn(2) == 0 {
				sig := req.NoCloserClosee.Zero()
				_, err := r.Read(sig.Val.bytes[:])
				if err != nil {
					t.Fatalf("unable to generate sig: %v",
						err)
					return
				}

				req.NoCloserClosee = tlv.SomeRecordT(sig)
			}
			if r.Intn(2) == 0 {
				sig := req.CloserAndClosee.Zero()
				_, err := r.Read(sig.Val.bytes[:])
				if err != nil {
					t.Fatalf("unable to generate sig: %v",
						err)
					return
				}

				req.CloserAndClosee = tlv.SomeRecordT(sig)
			}

			v[0] = reflect.ValueOf(req)
		},
		MsgClosingSig: func(v []reflect.Value, r *rand.Rand) {
			var c [32]byte
			_, err := r.Read(c[:])
			if err != nil {
				t.Fatalf("unable to generate chan id: %v", err)
				return
			}

			req := ClosingSig{
				ChannelID:   ChannelID(c),
				ClosingSigs: ClosingSigs{},
			}

			if r.Intn(2) == 0 {
				sig := req.CloserNoClosee.Zero()
				_, err := r.Read(sig.Val.bytes[:])
				if err != nil {
					t.Fatalf("unable to generate sig: %v",
						err)
					return
				}

				req.CloserNoClosee = tlv.SomeRecordT(sig)
			}
			if r.Intn(2) == 0 {
				sig := req.NoCloserClosee.Zero()
				_, err := r.Read(sig.Val.bytes[:])
				if err != nil {
					t.Fatalf("unable to generate sig: %v",
						err)
					return
				}

				req.NoCloserClosee = tlv.SomeRecordT(sig)
			}
			if r.Intn(2) == 0 {
				sig := req.CloserAndClosee.Zero()
				_, err := r.Read(sig.Val.bytes[:])
				if err != nil {
					t.Fatalf("unable to generate sig: %v",
						err)
					return
				}

				req.CloserAndClosee = tlv.SomeRecordT(sig)
			}

			v[0] = reflect.ValueOf(req)
		},
		MsgUpdateAddHTLC: func(v []reflect.Value, r *rand.Rand) {
			req := &UpdateAddHTLC{
				ID:     r.Uint64(),
				Amount: MilliSatoshi(r.Uint64()),
				Expiry: r.Uint32(),
			}

			_, err := r.Read(req.ChanID[:])
			require.NoError(t, err)

			_, err = r.Read(req.PaymentHash[:])
			require.NoError(t, err)

			_, err = r.Read(req.OnionBlob[:])
			require.NoError(t, err)

			req.CustomRecords = randCustomRecords(t, r)

			// Generate a blinding point 50% of the time, since not
			// all update adds will use route blinding.
			if r.Int31()%2 == 0 {
				pubkey, err := randPubKey()
				if err != nil {
					t.Fatalf("unable to generate key: %v",
						err)

					return
				}

				req.BlindingPoint = tlv.SomeRecordT(
					tlv.NewPrimitiveRecord[tlv.TlvType0](
						pubkey,
					),
				)
			}

			v[0] = reflect.ValueOf(*req)
		},
		MsgUpdateFulfillHTLC: func(v []reflect.Value, r *rand.Rand) {
			req := &UpdateFulfillHTLC{
				ID: r.Uint64(),
			}

			_, err := r.Read(req.ChanID[:])
			require.NoError(t, err)

			_, err = r.Read(req.PaymentPreimage[:])
			require.NoError(t, err)

			req.CustomRecords = randCustomRecords(t, r)

			// Generate some random TLV records 50% of the time.
			if r.Int31()%2 == 0 {
				req.ExtraData = []byte{
					0x01, 0x03, 1, 2, 3,
					0x02, 0x03, 4, 5, 6,
				}
			}

			v[0] = reflect.ValueOf(*req)
		},
	}

	// With the above types defined, we'll now generate a slice of
	// scenarios to feed into quick.Check. The function scans in input
	// space of the target function under test, so we'll need to create a
	// series of wrapper functions to force it to iterate over the target
	// types, but re-use the mainScenario defined above.
	tests := []struct {
		msgType  MessageType
		scenario interface{}
	}{
		{
			msgType: MsgStfu,
			scenario: func(m Stfu) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgInit,
			scenario: func(m Init) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgWarning,
			scenario: func(m Warning) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgError,
			scenario: func(m Error) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgPing,
			scenario: func(m Ping) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgPong,
			scenario: func(m Pong) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgOpenChannel,
			scenario: func(m OpenChannel) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgAcceptChannel,
			scenario: func(m AcceptChannel) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgFundingCreated,
			scenario: func(m FundingCreated) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgFundingSigned,
			scenario: func(m FundingSigned) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgChannelReady,
			scenario: func(m ChannelReady) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgShutdown,
			scenario: func(m Shutdown) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgClosingSigned,
			scenario: func(m ClosingSigned) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgDynPropose,
			scenario: func(m DynPropose) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgDynReject,
			scenario: func(m DynReject) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgDynAck,
			scenario: func(m DynAck) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgKickoffSig,
			scenario: func(m KickoffSig) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgUpdateAddHTLC,
			scenario: func(m UpdateAddHTLC) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgUpdateFulfillHTLC,
			scenario: func(m UpdateFulfillHTLC) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgUpdateFailHTLC,
			scenario: func(m UpdateFailHTLC) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgCommitSig,
			scenario: func(m CommitSig) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgRevokeAndAck,
			scenario: func(m RevokeAndAck) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgUpdateFee,
			scenario: func(m UpdateFee) bool {
				return mainScenario(&m)
			},
		},
		{

			msgType: MsgUpdateFailMalformedHTLC,
			scenario: func(m UpdateFailMalformedHTLC) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgChannelReestablish,
			scenario: func(m ChannelReestablish) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgChannelAnnouncement,
			scenario: func(m ChannelAnnouncement) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgNodeAnnouncement,
			scenario: func(m NodeAnnouncement) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgChannelUpdate,
			scenario: func(m ChannelUpdate) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgAnnounceSignatures,
			scenario: func(m AnnounceSignatures) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgGossipTimestampRange,
			scenario: func(m GossipTimestampRange) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgQueryShortChanIDs,
			scenario: func(m QueryShortChanIDs) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgReplyShortChanIDsEnd,
			scenario: func(m ReplyShortChanIDsEnd) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgQueryChannelRange,
			scenario: func(m QueryChannelRange) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgReplyChannelRange,
			scenario: func(m ReplyChannelRange) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgClosingComplete,
			scenario: func(m ClosingComplete) bool {
				return mainScenario(&m)
			},
		},
		{
			msgType: MsgClosingSig,
			scenario: func(m ClosingSig) bool {
				return mainScenario(&m)
			},
		},
	}
	for _, test := range tests {
		t.Run(test.msgType.String(), func(t *testing.T) {
			var config *quick.Config

			// If the type defined is within the custom type gen
			// map above, then we'll modify the default config to
			// use this Value function that knows how to generate
			// the proper types.
			if valueGen, ok := customTypeGen[test.msgType]; ok {
				config = &quick.Config{
					Values: valueGen,
				}
			}

			t.Logf("Running fuzz tests for msgType=%v",
				test.msgType)

			err := quick.Check(test.scenario, config)
			if err != nil {
				t.Fatalf("fuzz checks for msg=%v failed: %v",
					test.msgType, err)
			}
		})
	}

}

func init() {
	rand.Seed(time.Now().Unix())
}
