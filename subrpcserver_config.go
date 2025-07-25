package lnd

import (
	"fmt"
	"net"
	"reflect"

	"github.com/btcsuite/btcd/chaincfg"
	"github.com/btcsuite/btclog"
	"github.com/lightningnetwork/lnd/aliasmgr"
	"github.com/lightningnetwork/lnd/autopilot"
	"github.com/lightningnetwork/lnd/chainreg"
	"github.com/lightningnetwork/lnd/channeldb"
	"github.com/lightningnetwork/lnd/fn"
	"github.com/lightningnetwork/lnd/htlcswitch"
	"github.com/lightningnetwork/lnd/invoices"
	"github.com/lightningnetwork/lnd/lncfg"
	"github.com/lightningnetwork/lnd/lnrpc/autopilotrpc"
	"github.com/lightningnetwork/lnd/lnrpc/chainrpc"
	"github.com/lightningnetwork/lnd/lnrpc/devrpc"
	"github.com/lightningnetwork/lnd/lnrpc/invoicesrpc"
	"github.com/lightningnetwork/lnd/lnrpc/neutrinorpc"
	"github.com/lightningnetwork/lnd/lnrpc/peersrpc"
	"github.com/lightningnetwork/lnd/lnrpc/routerrpc"
	"github.com/lightningnetwork/lnd/lnrpc/signrpc"
	"github.com/lightningnetwork/lnd/lnrpc/walletrpc"
	"github.com/lightningnetwork/lnd/lnrpc/watchtowerrpc"
	"github.com/lightningnetwork/lnd/lnrpc/wtclientrpc"
	"github.com/lightningnetwork/lnd/lnwire"
	"github.com/lightningnetwork/lnd/macaroons"
	"github.com/lightningnetwork/lnd/netann"
	"github.com/lightningnetwork/lnd/routing"
	"github.com/lightningnetwork/lnd/sweep"
	"github.com/lightningnetwork/lnd/watchtower"
	"github.com/lightningnetwork/lnd/watchtower/wtclient"
	"google.golang.org/protobuf/proto"
)

// subRPCServerConfigs is special sub-config in the main configuration that
// houses the configuration for the optional sub-servers. These sub-RPC servers
// are meant to house experimental new features that may eventually make it
// into the main RPC server that lnd exposes. Special methods are present on
// this struct to allow the main RPC server to create and manipulate the
// sub-RPC servers in a generalized manner.
type subRPCServerConfigs struct {
	// SignRPC is a sub-RPC server that exposes signing of arbitrary inputs
	// as a gRPC service.
	SignRPC *signrpc.Config `group:"signrpc" namespace:"signrpc"`

	// WalletKitRPC is a sub-RPC server that exposes functionality allowing
	// a client to send transactions through a wallet, publish them, and
	// also requests keys and addresses under control of the backing
	// wallet.
	WalletKitRPC *walletrpc.Config `group:"walletrpc" namespace:"walletrpc"`

	// AutopilotRPC is a sub-RPC server that exposes methods on the running
	// autopilot as a gRPC service.
	AutopilotRPC *autopilotrpc.Config `group:"autopilotrpc" namespace:"autopilotrpc"`

	// ChainRPC is a sub-RPC server that exposes functionality allowing a
	// client to be notified of certain on-chain events (new blocks,
	// confirmations, spends).
	ChainRPC *chainrpc.Config `group:"chainrpc" namespace:"chainrpc"`

	// InvoicesRPC is a sub-RPC server that exposes invoice related methods
	// as a gRPC service.
	InvoicesRPC *invoicesrpc.Config `group:"invoicesrpc" namespace:"invoicesrpc"`

	// PeersRPC is a sub-RPC server that exposes peer related methods
	// as a gRPC service.
	PeersRPC *peersrpc.Config `group:"peersrpc" namespace:"peersrpc"`

	// NeutrinoKitRPC is a sub-RPC server that exposes functionality allowing
	// a client to interact with a running neutrino node.
	NeutrinoKitRPC *neutrinorpc.Config `group:"neutrinorpc" namespace:"neutrinorpc"`

	// RouterRPC is a sub-RPC server the exposes functionality that allows
	// clients to send payments on the network, and perform Lightning
	// payment related queries such as requests for estimates of off-chain
	// fees.
	RouterRPC *routerrpc.Config `group:"routerrpc" namespace:"routerrpc"`

	// WatchtowerRPC is a sub-RPC server that exposes functionality allowing
	// clients to monitor and control their embedded watchtower.
	WatchtowerRPC *watchtowerrpc.Config `group:"watchtowerrpc" namespace:"watchtowerrpc"`

	// WatchtowerClientRPC is a sub-RPC server that exposes functionality
	// that allows clients to interact with the active watchtower client
	// instance within lnd in order to add, remove, list registered client
	// towers, etc.
	WatchtowerClientRPC *wtclientrpc.Config `group:"wtclientrpc" namespace:"wtclientrpc"`

	// DevRPC is a sub-RPC server that exposes functionality that allows
	// developers manipulate LND state that is normally not possible.
	// Should only be used for development purposes.
	DevRPC *devrpc.Config `group:"devrpc" namespace:"devrpc"`
}

// PopulateDependencies attempts to iterate through all the sub-server configs
// within this struct, and populate the items it requires based on the main
// configuration file, and the chain control.
//
// NOTE: This MUST be called before any callers are permitted to execute the
// FetchConfig method.
func (s *subRPCServerConfigs) PopulateDependencies(cfg *Config,
	cc *chainreg.ChainControl,
	networkDir string, macService *macaroons.Service,
	atpl *autopilot.Manager,
	invoiceRegistry *invoices.InvoiceRegistry,
	htlcSwitch *htlcswitch.Switch,
	activeNetParams *chaincfg.Params,
	chanRouter *routing.ChannelRouter,
	routerBackend *routerrpc.RouterBackend,
	nodeSigner *netann.NodeSigner,
	graphDB *channeldb.ChannelGraph,
	chanStateDB *channeldb.ChannelStateDB,
	sweeper *sweep.UtxoSweeper,
	tower *watchtower.Standalone,
	towerClientMgr *wtclient.Manager,
	tcpResolver lncfg.TCPResolver,
	genInvoiceFeatures func() *lnwire.FeatureVector,
	genAmpInvoiceFeatures func() *lnwire.FeatureVector,
	getNodeAnnouncement func() lnwire.NodeAnnouncement,
	updateNodeAnnouncement func(features *lnwire.RawFeatureVector,
		modifiers ...netann.NodeAnnModifier) error,
	parseAddr func(addr string) (net.Addr, error),
	rpcLogger btclog.Logger, aliasMgr *aliasmgr.Manager,
	auxDataParser fn.Option[AuxDataParser],
	invoiceHtlcModifier *invoices.HtlcModificationInterceptor) error {

	// First, we'll use reflect to obtain a version of the config struct
	// that allows us to programmatically inspect its fields.
	selfVal := extractReflectValue(s)
	selfType := selfVal.Type()

	numFields := selfVal.NumField()
	for i := 0; i < numFields; i++ {
		field := selfVal.Field(i)
		fieldElem := field.Elem()
		fieldName := selfType.Field(i).Name

		ltndLog.Debugf("Populating dependencies for sub RPC "+
			"server: %v", fieldName)

		// If this sub-config doesn't actually have any fields, then we
		// can skip it, as the build tag for it is likely off.
		if fieldElem.NumField() == 0 {
			continue
		}
		if !fieldElem.CanSet() {
			continue
		}

		switch subCfg := field.Interface().(type) {
		case *signrpc.Config:
			subCfgValue := extractReflectValue(subCfg)

			subCfgValue.FieldByName("MacService").Set(
				reflect.ValueOf(macService),
			)
			subCfgValue.FieldByName("NetworkDir").Set(
				reflect.ValueOf(networkDir),
			)
			subCfgValue.FieldByName("Signer").Set(
				reflect.ValueOf(cc.Signer),
			)
			subCfgValue.FieldByName("KeyRing").Set(
				reflect.ValueOf(cc.KeyRing),
			)

		case *walletrpc.Config:
			subCfgValue := extractReflectValue(subCfg)

			subCfgValue.FieldByName("NetworkDir").Set(
				reflect.ValueOf(networkDir),
			)
			subCfgValue.FieldByName("MacService").Set(
				reflect.ValueOf(macService),
			)
			subCfgValue.FieldByName("FeeEstimator").Set(
				reflect.ValueOf(cc.FeeEstimator),
			)
			subCfgValue.FieldByName("Wallet").Set(
				reflect.ValueOf(cc.Wallet),
			)
			subCfgValue.FieldByName("CoinSelectionLocker").Set(
				reflect.ValueOf(cc.Wallet),
			)
			subCfgValue.FieldByName("KeyRing").Set(
				reflect.ValueOf(cc.KeyRing),
			)
			subCfgValue.FieldByName("Sweeper").Set(
				reflect.ValueOf(sweeper),
			)
			subCfgValue.FieldByName("Chain").Set(
				reflect.ValueOf(cc.ChainIO),
			)
			subCfgValue.FieldByName("ChainParams").Set(
				reflect.ValueOf(activeNetParams),
			)
			subCfgValue.FieldByName("CurrentNumAnchorChans").Set(
				reflect.ValueOf(cc.Wallet.CurrentNumAnchorChans),
			)
			subCfgValue.FieldByName("CoinSelectionStrategy").Set(
				reflect.ValueOf(
					cc.Wallet.Cfg.CoinSelectionStrategy,
				),
			)

		case *autopilotrpc.Config:
			subCfgValue := extractReflectValue(subCfg)

			subCfgValue.FieldByName("Manager").Set(
				reflect.ValueOf(atpl),
			)

		case *chainrpc.Config:
			subCfgValue := extractReflectValue(subCfg)

			subCfgValue.FieldByName("NetworkDir").Set(
				reflect.ValueOf(networkDir),
			)
			subCfgValue.FieldByName("MacService").Set(
				reflect.ValueOf(macService),
			)
			subCfgValue.FieldByName("ChainNotifier").Set(
				reflect.ValueOf(cc.ChainNotifier),
			)
			subCfgValue.FieldByName("Chain").Set(
				reflect.ValueOf(cc.ChainIO),
			)

		case *invoicesrpc.Config:
			subCfgValue := extractReflectValue(subCfg)

			subCfgValue.FieldByName("NetworkDir").Set(
				reflect.ValueOf(networkDir),
			)
			subCfgValue.FieldByName("MacService").Set(
				reflect.ValueOf(macService),
			)
			subCfgValue.FieldByName("InvoiceRegistry").Set(
				reflect.ValueOf(invoiceRegistry),
			)
			subCfgValue.FieldByName("HtlcModifier").Set(
				reflect.ValueOf(invoiceHtlcModifier),
			)
			subCfgValue.FieldByName("IsChannelActive").Set(
				reflect.ValueOf(htlcSwitch.HasActiveLink),
			)
			subCfgValue.FieldByName("ChainParams").Set(
				reflect.ValueOf(activeNetParams),
			)
			subCfgValue.FieldByName("NodeSigner").Set(
				reflect.ValueOf(nodeSigner),
			)
			defaultDelta := cfg.Bitcoin.TimeLockDelta
			subCfgValue.FieldByName("DefaultCLTVExpiry").Set(
				reflect.ValueOf(defaultDelta),
			)
			subCfgValue.FieldByName("GraphDB").Set(
				reflect.ValueOf(graphDB),
			)
			subCfgValue.FieldByName("ChanStateDB").Set(
				reflect.ValueOf(chanStateDB),
			)
			subCfgValue.FieldByName("GenInvoiceFeatures").Set(
				reflect.ValueOf(genInvoiceFeatures),
			)
			subCfgValue.FieldByName("GenAmpInvoiceFeatures").Set(
				reflect.ValueOf(genAmpInvoiceFeatures),
			)
			subCfgValue.FieldByName("GetAlias").Set(
				reflect.ValueOf(aliasMgr.GetPeerAlias),
			)

			parseAuxData := func(m proto.Message) error {
				return fn.MapOptionZ(
					auxDataParser,
					func(p AuxDataParser) error {
						return p.InlineParseCustomData(
							m,
						)
					},
				)
			}
			subCfgValue.FieldByName("ParseAuxData").Set(
				reflect.ValueOf(parseAuxData),
			)

		case *neutrinorpc.Config:
			subCfgValue := extractReflectValue(subCfg)

			subCfgValue.FieldByName("NeutrinoCS").Set(
				reflect.ValueOf(cc.Cfg.NeutrinoCS),
			)

		// RouterRPC isn't conditionally compiled and doesn't need to be
		// populated using reflection.
		case *routerrpc.Config:
			subCfgValue := extractReflectValue(subCfg)

			subCfgValue.FieldByName("AliasMgr").Set(
				reflect.ValueOf(aliasMgr),
			)

		case *watchtowerrpc.Config:
			subCfgValue := extractReflectValue(subCfg)

			subCfgValue.FieldByName("Active").Set(
				reflect.ValueOf(tower != nil),
			)
			subCfgValue.FieldByName("Tower").Set(
				reflect.ValueOf(tower),
			)

		case *wtclientrpc.Config:
			subCfgValue := extractReflectValue(subCfg)

			if towerClientMgr != nil {
				subCfgValue.FieldByName("Active").Set(
					reflect.ValueOf(towerClientMgr != nil),
				)
				subCfgValue.FieldByName("ClientMgr").Set(
					reflect.ValueOf(towerClientMgr),
				)
			}
			subCfgValue.FieldByName("Resolver").Set(
				reflect.ValueOf(tcpResolver),
			)
			subCfgValue.FieldByName("Log").Set(
				reflect.ValueOf(rpcLogger),
			)

		case *devrpc.Config:
			subCfgValue := extractReflectValue(subCfg)

			subCfgValue.FieldByName("ActiveNetParams").Set(
				reflect.ValueOf(activeNetParams),
			)

			subCfgValue.FieldByName("GraphDB").Set(
				reflect.ValueOf(graphDB),
			)

		case *peersrpc.Config:
			subCfgValue := extractReflectValue(subCfg)

			subCfgValue.FieldByName("GetNodeAnnouncement").Set(
				reflect.ValueOf(getNodeAnnouncement),
			)

			subCfgValue.FieldByName("ParseAddr").Set(
				reflect.ValueOf(parseAddr),
			)

			subCfgValue.FieldByName("UpdateNodeAnnouncement").Set(
				reflect.ValueOf(updateNodeAnnouncement),
			)

		default:
			return fmt.Errorf("unknown field: %v, %T", fieldName,
				cfg)
		}
	}

	// Populate routerrpc dependencies.
	s.RouterRPC.NetworkDir = networkDir
	s.RouterRPC.MacService = macService
	s.RouterRPC.Router = chanRouter
	s.RouterRPC.RouterBackend = routerBackend

	return nil
}

// FetchConfig attempts to locate an existing configuration file mapped to the
// target sub-server. If we're unable to find a config file matching the
// subServerName name, then false will be returned for the second parameter.
//
// NOTE: Part of the lnrpc.SubServerConfigDispatcher interface.
func (s *subRPCServerConfigs) FetchConfig(subServerName string) (interface{}, bool) {
	// First, we'll use reflect to obtain a version of the config struct
	// that allows us to programmatically inspect its fields.
	selfVal := extractReflectValue(s)

	// Now that we have the value of the struct, we can check to see if it
	// has an attribute with the same name as the subServerName.
	configVal := selfVal.FieldByName(subServerName)

	// We'll now ensure that this field actually exists in this value. If
	// not, then we'll return false for the ok value to indicate to the
	// caller that this field doesn't actually exist.
	if !configVal.IsValid() {
		return nil, false
	}

	configValElem := configVal.Elem()

	// If a config of this type is found, it doesn't have any fields, then
	// it's the same as if it wasn't present. This can happen if the build
	// tag for the sub-server is inactive.
	if configValElem.NumField() == 0 {
		return nil, false
	}

	// At this pint, we know that the field is actually present in the
	// config struct, so we can return it directly.
	return configVal.Interface(), true
}

// extractReflectValue attempts to extract the value from an interface using
// the reflect package. The resulting reflect.Value allows the caller to
// programmatically examine and manipulate the underlying value.
func extractReflectValue(instance interface{}) reflect.Value {
	var val reflect.Value

	// If the type of the instance is a pointer, then we need to deference
	// the pointer one level to get its value. Otherwise, we can access the
	// value directly.
	if reflect.TypeOf(instance).Kind() == reflect.Ptr {
		val = reflect.ValueOf(instance).Elem()
	} else {
		val = reflect.ValueOf(instance)
	}

	return val
}
