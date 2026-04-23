#!/usr/bin/env bash
export HOME=~
set -eux pipefail
mkdir -p ~/.blakecoin
cat > ~/.blakecoin/blakecoin.conf <<EOF
regtest=1
txindex=1
printtoconsole=1
rpcuser=doggman
rpcpassword=donkey
rpcallowip=127.0.0.1
zmqpubrawblock=tcp://127.0.0.1:28332
zmqpubrawtx=tcp://127.0.0.1:28333
fallbackfee=0.0002
[regtest]
rpcbind=0.0.0.0
rpcport=18554
EOF
rm -rf ~/.blakecoin/regtest
blakecoind -regtest &
sleep 6
blakecoin-cli createwallet test_wallet
addr=$(blakecoin-cli getnewaddress)
blakecoin-cli generatetoaddress 150 $addr
tail -f ~/.blakecoin/regtest/debug.log
