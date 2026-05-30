curl -X POST "http://localhost:8085/message?session_id=YOUR_SESSION_ID" \
     -H "Content-Type: application/json" \
     -d '{
           "jsonrpc": "2.0",
           "id": 1,
           "method": "tools/list"
         }'