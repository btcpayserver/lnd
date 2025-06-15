package lnd

import (
	"testing"

	"github.com/btcsuite/btcd/btcec/v2"
	"github.com/lightningnetwork/lnd/channeldb"
	"github.com/stretchr/testify/require"
)

// assertInboundConnection asserts that we're able to accept an inbound
// connection successfully without any access permissions being violated.
func assertInboundConnection(t *testing.T, a *accessMan,
	remotePub *btcec.PublicKey, status peerAccessStatus) {

	remotePubSer := string(remotePub.SerializeCompressed())

	isSlotAvailable, err := a.checkIncomingConnBanScore(remotePub)
	require.NoError(t, err)
	require.True(t, isSlotAvailable)

	peerAccess, err := a.assignPeerPerms(remotePub)
	require.NoError(t, err)
	require.Equal(t, status, peerAccess)

	a.addPeerAccess(remotePub, peerAccess)
	peerScore, ok := a.peerScores[remotePubSer]
	require.True(t, ok)
	require.Equal(t, status, peerScore.state)
}

func assertAccessState(t *testing.T, a *accessMan, remotePub *btcec.PublicKey,
	expectedStatus peerAccessStatus) {

	remotePubSer := string(remotePub.SerializeCompressed())
	peerScore, ok := a.peerScores[remotePubSer]
	require.True(t, ok)
	require.Equal(t, expectedStatus, peerScore.state)
}

// TestAccessManRestrictedSlots tests that the configurable number of
// restricted slots are properly allocated. It also tests that certain peers
// with access permissions are allowed to bypass the slot mechanism.
func TestAccessManRestrictedSlots(t *testing.T) {
	t.Parallel()

	// We'll pre-populate the map to mock the database fetch. We'll make
	// three peers. One has an open/closed channel. One has both an open
	// / closed channel and a pending channel. The last one has only a
	// pending channel.
	peerPriv1, err := btcec.NewPrivateKey()
	require.NoError(t, err)
	peerKey1 := peerPriv1.PubKey()
	peerKeySer1 := string(peerKey1.SerializeCompressed())

	peerPriv2, err := btcec.NewPrivateKey()
	require.NoError(t, err)
	peerKey2 := peerPriv2.PubKey()
	peerKeySer2 := string(peerKey2.SerializeCompressed())

	peerPriv3, err := btcec.NewPrivateKey()
	require.NoError(t, err)
	peerKey3 := peerPriv3.PubKey()
	peerKeySer3 := string(peerKey3.SerializeCompressed())

	initPerms := func() (map[string]channeldb.ChanCount, error) {
		return map[string]channeldb.ChanCount{
			peerKeySer1: {
				HasOpenOrClosedChan: true,
			},
			peerKeySer2: {
				HasOpenOrClosedChan: true,
				PendingOpenCount:    1,
			},
			peerKeySer3: {
				HasOpenOrClosedChan: false,
				PendingOpenCount:    1,
			},
		}, nil
	}

	disconnect := func(*btcec.PublicKey) (bool, error) {
		return false, nil
	}

	cfg := &accessManConfig{
		initAccessPerms:    initPerms,
		shouldDisconnect:   disconnect,
		maxRestrictedSlots: 1,
	}

	a, err := newAccessMan(cfg)
	require.NoError(t, err)

	// Check that the peerCounts map is correctly populated with three
	// peers.
	require.Equal(t, 0, int(a.numRestricted))
	require.Equal(t, 3, len(a.peerCounts))

	peerCount1, ok := a.peerCounts[peerKeySer1]
	require.True(t, ok)
	require.True(t, peerCount1.HasOpenOrClosedChan)
	require.Equal(t, 0, int(peerCount1.PendingOpenCount))

	peerCount2, ok := a.peerCounts[peerKeySer2]
	require.True(t, ok)
	require.True(t, peerCount2.HasOpenOrClosedChan)
	require.Equal(t, 1, int(peerCount2.PendingOpenCount))

	peerCount3, ok := a.peerCounts[peerKeySer3]
	require.True(t, ok)
	require.False(t, peerCount3.HasOpenOrClosedChan)
	require.Equal(t, 1, int(peerCount3.PendingOpenCount))

	// We'll now start to connect the peers. We'll add a new fourth peer
	// that will take up the restricted slot. The first three peers should
	// be able to bypass this restricted slot mechanism.
	peerPriv4, err := btcec.NewPrivateKey()
	require.NoError(t, err)
	peerKey4 := peerPriv4.PubKey()

	// Follow the normal process of an incoming connection. We check if we
	// can accommodate this peer in checkIncomingConnBanScore and then we
	// assign its access permissions and then insert into the map.
	assertInboundConnection(t, a, peerKey4, peerStatusRestricted)

	// Connect the three peers. This should happen without any issue.
	assertInboundConnection(t, a, peerKey1, peerStatusProtected)
	assertInboundConnection(t, a, peerKey2, peerStatusProtected)
	assertInboundConnection(t, a, peerKey3, peerStatusTemporary)

	// Check that a pending-open channel promotes the restricted peer.
	err = a.newPendingOpenChan(peerKey4)
	require.NoError(t, err)
	assertAccessState(t, a, peerKey4, peerStatusTemporary)

	// Check that an open channel promotes the temporary peer.
	err = a.newOpenChan(peerKey3)
	require.NoError(t, err)
	assertAccessState(t, a, peerKey3, peerStatusProtected)

	// We should be able to accommodate a new peer.
	peerPriv5, err := btcec.NewPrivateKey()
	require.NoError(t, err)
	peerKey5 := peerPriv5.PubKey()

	assertInboundConnection(t, a, peerKey5, peerStatusRestricted)

	// Check that a pending-close channel event for peer 4 demotes the
	// peer.
	err = a.newPendingCloseChan(peerKey4)
	require.ErrorIs(t, err, ErrNoMoreRestrictedAccessSlots)
}

// TestAssignPeerPerms asserts that the peer's access status is correctly
// assigned.
func TestAssignPeerPerms(t *testing.T) {
	t.Parallel()

	// genPeerPub is a helper closure that generates a random public key.
	genPeerPub := func() *btcec.PublicKey {
		peerPriv, err := btcec.NewPrivateKey()
		require.NoError(t, err)

		return peerPriv.PubKey()
	}

	disconnect := func(_ *btcec.PublicKey) (bool, error) {
		return true, nil
	}

	noDisconnect := func(_ *btcec.PublicKey) (bool, error) {
		return false, nil
	}

	var testCases = []struct {
		name             string
		peerPub          *btcec.PublicKey
		chanCount        channeldb.ChanCount
		shouldDisconnect func(*btcec.PublicKey) (bool, error)
		numRestricted    int

		expectedStatus peerAccessStatus
		expectedErr    error
	}{
		// peer1 has a channel with us, and we expect it to have a
		// protected status.
		{
			name:    "peer with channels",
			peerPub: genPeerPub(),
			chanCount: channeldb.ChanCount{
				HasOpenOrClosedChan: true,
			},
			shouldDisconnect: noDisconnect,
			expectedStatus:   peerStatusProtected,
			expectedErr:      nil,
		},
		// peer2 has a channel open and a pending channel with us, we
		// expect it to have a protected status.
		{
			name:    "peer with channels and pending channels",
			peerPub: genPeerPub(),
			chanCount: channeldb.ChanCount{
				HasOpenOrClosedChan: true,
				PendingOpenCount:    1,
			},
			shouldDisconnect: noDisconnect,
			expectedStatus:   peerStatusProtected,
			expectedErr:      nil,
		},
		// peer3 has a pending channel with us, and we expect it to have
		// a temporary status.
		{
			name:    "peer with pending channels",
			peerPub: genPeerPub(),
			chanCount: channeldb.ChanCount{
				HasOpenOrClosedChan: false,
				PendingOpenCount:    1,
			},
			shouldDisconnect: noDisconnect,
			expectedStatus:   peerStatusTemporary,
			expectedErr:      nil,
		},
		// peer4 has no channel with us, and we expect it to have a
		// restricted status.
		{
			name:    "peer with no channels",
			peerPub: genPeerPub(),
			chanCount: channeldb.ChanCount{
				HasOpenOrClosedChan: false,
				PendingOpenCount:    0,
			},
			shouldDisconnect: noDisconnect,
			expectedStatus:   peerStatusRestricted,
			expectedErr:      nil,
		},
		// peer5 has no channel with us, and we expect it to have a
		// restricted status. We also expect the error `ErrGossiperBan`
		// to be returned given we will use a mocked `shouldDisconnect`
		// in this test to disconnect on peer5 only.
		{
			name:    "peer with no channels and banned",
			peerPub: genPeerPub(),
			chanCount: channeldb.ChanCount{
				HasOpenOrClosedChan: false,
				PendingOpenCount:    0,
			},
			shouldDisconnect: disconnect,
			expectedStatus:   peerStatusRestricted,
			expectedErr:      ErrGossiperBan,
		},
		// peer6 has no channel with us, and we expect it to have a
		// restricted status. We also expect the error
		// `ErrNoMoreRestrictedAccessSlots` to be returned given
		// we only allow 1 restricted peer in this test.
		{
			name:    "peer with no channels and restricted",
			peerPub: genPeerPub(),
			chanCount: channeldb.ChanCount{
				HasOpenOrClosedChan: false,
				PendingOpenCount:    0,
			},
			shouldDisconnect: noDisconnect,
			numRestricted:    1,

			expectedStatus: peerStatusRestricted,
			expectedErr:    ErrNoMoreRestrictedAccessSlots,
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			peerStr := string(tc.peerPub.SerializeCompressed())

			initPerms := func() (map[string]channeldb.ChanCount,
				error) {

				return map[string]channeldb.ChanCount{
					peerStr: tc.chanCount,
				}, nil
			}

			cfg := &accessManConfig{
				initAccessPerms:    initPerms,
				shouldDisconnect:   tc.shouldDisconnect,
				maxRestrictedSlots: 1,
			}

			a, err := newAccessMan(cfg)
			require.NoError(t, err)

			// Initialize the internal state of the accessman.
			a.numRestricted = int64(tc.numRestricted)

			status, err := a.assignPeerPerms(tc.peerPub)
			require.Equal(t, tc.expectedStatus, status)
			require.ErrorIs(t, tc.expectedErr, err)
		})
	}
}

// TestAssignPeerPermsBypassRestriction asserts that when a peer has a channel
// with us, either it being open, pending, or closed, no restriction is placed
// on this peer.
func TestAssignPeerPermsBypassRestriction(t *testing.T) {
	t.Parallel()

	// genPeerPub is a helper closure that generates a random public key.
	genPeerPub := func() *btcec.PublicKey {
		peerPriv, err := btcec.NewPrivateKey()
		require.NoError(t, err)

		return peerPriv.PubKey()
	}

	// Mock shouldDisconnect to always return true and assert that it has no
	// effect on the peer.
	disconnect := func(_ *btcec.PublicKey) (bool, error) {
		return true, nil
	}

	var testCases = []struct {
		name           string
		peerPub        *btcec.PublicKey
		chanCount      channeldb.ChanCount
		expectedStatus peerAccessStatus
	}{
		// peer1 has a channel with us, and we expect it to have a
		// protected status.
		{
			name:    "peer with channels",
			peerPub: genPeerPub(),
			chanCount: channeldb.ChanCount{
				HasOpenOrClosedChan: true,
			},
			expectedStatus: peerStatusProtected,
		},
		// peer2 has a channel open and a pending channel with us, we
		// expect it to have a protected status.
		{
			name:    "peer with channels and pending channels",
			peerPub: genPeerPub(),
			chanCount: channeldb.ChanCount{
				HasOpenOrClosedChan: true,
				PendingOpenCount:    1,
			},
			expectedStatus: peerStatusProtected,
		},
		// peer3 has a pending channel with us, and we expect it to have
		// a temporary status.
		{
			name:    "peer with pending channels",
			peerPub: genPeerPub(),
			chanCount: channeldb.ChanCount{
				HasOpenOrClosedChan: false,
				PendingOpenCount:    1,
			},
			expectedStatus: peerStatusTemporary,
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			peerStr := string(tc.peerPub.SerializeCompressed())

			initPerms := func() (map[string]channeldb.ChanCount,
				error) {

				return map[string]channeldb.ChanCount{
					peerStr: tc.chanCount,
				}, nil
			}

			// Config the accessman such that it has zero max slots
			// and always return true on `shouldDisconnect`. We
			// should see the peers in this test are not affected by
			// these checks.
			cfg := &accessManConfig{
				initAccessPerms:    initPerms,
				shouldDisconnect:   disconnect,
				maxRestrictedSlots: 0,
			}

			a, err := newAccessMan(cfg)
			require.NoError(t, err)

			status, err := a.assignPeerPerms(tc.peerPub)
			require.NoError(t, err)
			require.Equal(t, tc.expectedStatus, status)
		})
	}
}
