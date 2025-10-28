#!/bin/bash
# TwelveData API Research Test Script
# Tests all requirements for market data integration

API_KEY="1949ee4a31a64711874dcd22c08f54c8"
BASE_URL="https://api.twelvedata.com"

echo "=========================================="
echo "TwelveData API Research Test"
echo "=========================================="
echo ""

# Test 1: API Access and Account Status
echo "Test 1: API Access & Account Status"
echo "-----------------------------------"
curl -s "${BASE_URL}/api_usage?apikey=${API_KEY}" | jq '.'
echo ""
sleep 2

# Test 2: 60+ Days Historical Data
echo "Test 2: Historical Data Availability (60+ days)"
echo "------------------------------------------------"
START_DATE=$(date -u -v-70d +"%Y-%m-%d" 2>/dev/null || date -u -d "70 days ago" +"%Y-%m-%d")
END_DATE=$(date -u +"%Y-%m-%d")
echo "Testing date range: ${START_DATE} to ${END_DATE}"

RESULT=$(curl -s "${BASE_URL}/time_series?symbol=SPY&interval=1h&start_date=${START_DATE}&end_date=${END_DATE}&apikey=${API_KEY}")
COUNT=$(echo "$RESULT" | jq '.values | length')
FIRST_DATE=$(echo "$RESULT" | jq -r '.values[-1].datetime')
LAST_DATE=$(echo "$RESULT" | jq -r '.values[0].datetime')

echo "Bars returned: ${COUNT}"
echo "Date range: ${FIRST_DATE} to ${LAST_DATE}"
echo ""
sleep 2

# Test 3: Real-time/Recent Data
echo "Test 3: Recent Data Access (last 24 hours)"
echo "-------------------------------------------"
RECENT_RESULT=$(curl -s "${BASE_URL}/time_series?symbol=SPY&interval=1h&outputsize=24&apikey=${API_KEY}")
RECENT_COUNT=$(echo "$RECENT_RESULT" | jq '.values | length')
MOST_RECENT=$(echo "$RECENT_RESULT" | jq -r '.values[0].datetime')

echo "Recent bars: ${RECENT_COUNT}"
echo "Most recent: ${MOST_RECENT}"
echo ""
sleep 2

# Test 4: All 6 Assets Coverage
echo "Test 4: Asset Coverage (SPY, QQQ, DIA, IWM, GLD, TLT)"
echo "------------------------------------------------------"
for SYMBOL in SPY QQQ DIA IWM GLD TLT; do
  ASSET_RESULT=$(curl -s "${BASE_URL}/time_series?symbol=${SYMBOL}&interval=1h&outputsize=5&apikey=${API_KEY}")
  STATUS=$(echo "$ASSET_RESULT" | jq -r '.status')
  ASSET_NAME=$(echo "$ASSET_RESULT" | jq -r '.meta.symbol')

  if [ "$STATUS" = "ok" ]; then
    echo "✓ ${SYMBOL}: Available (${ASSET_NAME})"
  else
    echo "✗ ${SYMBOL}: Error - $(echo "$ASSET_RESULT" | jq -r '.message')"
  fi
  sleep 2
done
echo ""

# Test 5: Data Quality Check
echo "Test 5: Data Quality & Format"
echo "------------------------------"
SAMPLE=$(curl -s "${BASE_URL}/time_series?symbol=SPY&interval=1h&outputsize=1&apikey=${API_KEY}")
echo "Sample bar structure:"
echo "$SAMPLE" | jq '.values[0]'
echo ""
echo "Meta information:"
echo "$SAMPLE" | jq '.meta'
echo ""
sleep 2

# Test 6: Rate Limit Testing
echo "Test 6: Rate Limit Behavior"
echo "----------------------------"
echo "Making rapid requests to test per-minute limit..."

for i in {1..10}; do
  RATE_TEST=$(curl -s "${BASE_URL}/time_series?symbol=SPY&interval=1h&outputsize=1&apikey=${API_KEY}")
  STATUS=$(echo "$RATE_TEST" | jq -r '.status')
  CODE=$(echo "$RATE_TEST" | jq -r '.code')

  if [ "$STATUS" = "error" ] && [ "$CODE" = "429" ]; then
    echo "✓ Rate limit triggered at request #${i}"
    echo "  Message: $(echo "$RATE_TEST" | jq -r '.message')"
    break
  else
    echo "  Request #${i}: OK"
  fi
done
echo ""

# Test 7: Final Usage Check
echo "Test 7: Final API Usage Status"
echo "--------------------------------"
curl -s "${BASE_URL}/api_usage?apikey=${API_KEY}" | jq '.'
echo ""

echo "=========================================="
echo "Test Complete"
echo "=========================================="
