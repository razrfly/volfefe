#!/usr/bin/env python3
"""
Polymarket API Research Script
Tests authenticated and public endpoints to understand data access patterns.
"""

import os
import json
import sys
from eth_account import Account

# Generate a new test wallet (or load existing)
WALLET_FILE = "test_wallet.json"

def create_or_load_wallet():
    """Create a new wallet or load existing one."""
    if os.path.exists(WALLET_FILE):
        with open(WALLET_FILE, 'r') as f:
            data = json.load(f)
            print(f"Loaded existing wallet: {data['address']}")
            return data['private_key'], data['address']

    # Generate new wallet
    account = Account.create()
    wallet_data = {
        'address': account.address,
        'private_key': account.key.hex()
    }

    with open(WALLET_FILE, 'w') as f:
        json.dump(wallet_data, f, indent=2)

    print(f"Created new wallet: {account.address}")
    print(f"Private key saved to {WALLET_FILE}")
    print("\nWARNING: This is a TEST wallet. Never send real funds to it.")

    return account.key.hex(), account.address


def test_public_endpoints():
    """Test public API endpoints."""
    import httpx

    print("\n" + "="*60)
    print("TESTING PUBLIC ENDPOINTS")
    print("="*60)

    # Test Gamma API - Markets
    print("\n1. Gamma API - Active Markets:")
    try:
        resp = httpx.get("https://gamma-api.polymarket.com/markets?closed=false&limit=3", timeout=30)
        data = resp.json()
        if isinstance(data, list) and len(data) > 0:
            print(f"   ✅ Success! Found {len(data)} markets")
            market = data[0]
            print(f"   Sample: {market.get('question', 'N/A')[:60]}...")
            print(f"   Volume: ${market.get('volumeNum', 0):,.2f}")
            print(f"   conditionId: {market.get('conditionId', 'N/A')[:20]}...")
            return market.get('conditionId')
    except Exception as e:
        print(f"   ❌ Error: {e}")

    return None


def test_trades_endpoint_public(condition_id):
    """Test if trades endpoint works without auth."""
    import httpx

    print("\n2. CLOB API - Trades (NO AUTH):")
    try:
        resp = httpx.get(f"https://clob.polymarket.com/trades?market={condition_id}&limit=5", timeout=30)
        data = resp.json()
        print(f"   Response: {json.dumps(data, indent=2)[:500]}")

        if 'error' in data:
            print(f"   ❌ Auth required: {data['error']}")
            return False
        else:
            print(f"   ✅ Public access works!")
            return True
    except Exception as e:
        print(f"   ❌ Error: {e}")
        return False


def test_authenticated_api(private_key):
    """Test authenticated API endpoints."""
    print("\n" + "="*60)
    print("TESTING AUTHENTICATED ENDPOINTS")
    print("="*60)

    try:
        from py_clob_client.client import ClobClient
        from py_clob_client.clob_types import ApiCreds

        print("\n3. Initializing CLOB Client...")

        # Initialize client with private key
        client = ClobClient(
            host="https://clob.polymarket.com",
            chain_id=137,  # Polygon mainnet
            key=private_key
        )

        print("   ✅ Client initialized")

        # Try to derive/create API key
        print("\n4. Deriving API Credentials...")
        try:
            api_creds = client.create_or_derive_api_creds()
            print(f"   ✅ Got API credentials!")
            print(f"   API Key: {api_creds.api_key[:20]}..." if api_creds.api_key else "   No API key")

            # Now try to get trades
            print("\n5. Testing /trades with auth...")
            try:
                # Get markets first
                markets = client.get_markets()
                if markets and hasattr(markets, 'data') and len(markets.data) > 0:
                    market = markets.data[0]
                    condition_id = market.condition_id
                    print(f"   Using market: {condition_id[:30]}...")

                    # Try to get trades for this market
                    trades = client.get_trades(market=condition_id)
                    print(f"   Trades response type: {type(trades)}")
                    print(f"   Trades: {trades}")

                    if trades:
                        print(f"   ✅ Got trades data!")
                        # Check if we can see wallet addresses
                        if hasattr(trades, '__iter__'):
                            for trade in list(trades)[:3]:
                                print(f"   Trade: {trade}")
                    else:
                        print("   ⚠️ No trades returned (might be empty market)")

            except Exception as e:
                print(f"   ❌ Trades error: {e}")

            # Try to get MY trades (authenticated user's trades)
            print("\n6. Getting MY trades (authenticated)...")
            try:
                my_trades = client.get_trades()
                print(f"   My trades: {my_trades}")
            except Exception as e:
                print(f"   ❌ My trades error: {e}")

        except Exception as e:
            print(f"   ❌ API creds error: {e}")
            import traceback
            traceback.print_exc()

    except ImportError as e:
        print(f"   ❌ Import error: {e}")
    except Exception as e:
        print(f"   ❌ Error: {e}")
        import traceback
        traceback.print_exc()


def test_market_trade_events():
    """Test getMarketTradesEvents which should be public."""
    import httpx

    print("\n" + "="*60)
    print("TESTING MARKET TRADE EVENTS (Should be PUBLIC)")
    print("="*60)

    # First get an active market
    try:
        resp = httpx.get("https://gamma-api.polymarket.com/markets?closed=false&limit=1", timeout=30)
        markets = resp.json()
        if markets:
            condition_id = markets[0].get('conditionId')
            print(f"\n7. Testing trade events for market: {condition_id[:30]}...")

            # Try different endpoints
            endpoints = [
                f"https://clob.polymarket.com/markets/{condition_id}/trades",
                f"https://clob.polymarket.com/trade-events?conditionID={condition_id}",
                f"https://data-api.polymarket.com/trades?market={condition_id}",
            ]

            for endpoint in endpoints:
                print(f"\n   Trying: {endpoint[:60]}...")
                try:
                    resp = httpx.get(endpoint, timeout=30)
                    data = resp.json() if resp.status_code == 200 else resp.text
                    print(f"   Status: {resp.status_code}")
                    print(f"   Response: {str(data)[:300]}")
                except Exception as e:
                    print(f"   Error: {e}")

    except Exception as e:
        print(f"   ❌ Error: {e}")


def main():
    print("="*60)
    print("POLYMARKET API RESEARCH")
    print("="*60)

    # Create or load wallet
    private_key, address = create_or_load_wallet()

    # Test public endpoints first
    condition_id = test_public_endpoints()

    # Test trades endpoint without auth
    if condition_id:
        test_trades_endpoint_public(condition_id)

    # Test market trade events
    test_market_trade_events()

    # Test authenticated endpoints
    test_authenticated_api(private_key)

    print("\n" + "="*60)
    print("RESEARCH COMPLETE")
    print("="*60)


if __name__ == "__main__":
    main()
