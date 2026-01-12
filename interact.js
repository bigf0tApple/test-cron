const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');
const readline = require('readline');

// CONFIG
const RPC_URL = 'https://mainnet.base.org';

// KNOWN CONTRACTS
const CONTRACTS = {
    'RewardsContract': '0x38CA26db29ad6828DDB1a147d9aCfD46DAFf3Ee6',
    'MainToken': '0x0f385E45624B83cF4F539F298999944BDD3CCfaA',
    'NFTContract': '0x099A407E30aD53545E7C8CeeCbf1992a4d972e6f',
    'TokenTracker': '0xaF6b80AF06119F66D96aFcDF798F11c30aeA45eA'
};

const ABIS = {
    'RewardsContract': require('../../WEE Dashboard/abi/RewardsContract.json'),
    'MainToken': require('../../WEE Dashboard/abi/MainToken.json'),
    'NFTContract': require('../../WEE Dashboard/abi/NFTContract.json'),
    'TokenTracker': require('../../WEE Dashboard/abi/TokenTracker.json')
};

const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout
});

const provider = new ethers.providers.JsonRpcProvider(RPC_URL);

async function main() {
    console.log('\n=== WEE CLI INTERACTOR ===');
    console.log('Using RPC:', RPC_URL);
    console.log('\nAvailable Contracts:');
    const keys = Object.keys(CONTRACTS);
    keys.forEach((k, i) => console.log(`${i + 1}. ${k} (${CONTRACTS[k]})`));

    rl.question('\nSelect Contract (number): ', async (ans) => {
        const idx = parseInt(ans) - 1;
        if (isNaN(idx) || idx < 0 || idx >= keys.length) {
            console.log('Invalid selection');
            rl.close();
            return;
        }

        const name = keys[idx];
        const address = CONTRACTS[name];
        const abi = ABIS[name];

        console.log(`\nSelected: ${name} at ${address}`);
        const contract = new ethers.Contract(address, abi, provider);

        const viewFns = abi.filter(x => x.type === 'function' && (x.stateMutability === 'view' || x.stateMutability === 'pure'));

        console.log('\nRead Functions:');
        viewFns.forEach((fn, i) => console.log(`${i + 1}. ${fn.name}(${fn.inputs.map(x => x.type).join(', ')})`));

        rl.question('\nSelect Function (number) or "q" to quit: ', async (fnAns) => {
            if (fnAns.toLowerCase() === 'q') {
                rl.close();
                return;
            }

            const fnIdx = parseInt(fnAns) - 1;
            if (isNaN(fnIdx) || fnIdx < 0 || fnIdx >= viewFns.length) {
                console.log('Invalid function');
                rl.close();
                return;
            }

            const fn = viewFns[fnIdx];
            console.log(`\nCalling ${fn.name}...`);

            let args = [];
            if (fn.inputs.length > 0) {
                console.log('Function requires arguments:', fn.inputs.map(i => i.name + '(' + i.type + ')').join(', '));
                rl.question('Enter arguments (comma separated) or ENTER if none: ', async (argsStr) => {
                    if (argsStr.trim()) {
                        args = argsStr.split(',').map(s => s.trim());
                    }
                    try {
                        const res = await contract[fn.name](...args);
                        console.log(`\nRESULT: ${res.toString()}`);
                    } catch (e) {
                        console.error('ERROR:', e.reason || e.message);
                    }
                    rl.close();
                });
            } else {
                try {
                    const res = await contract[fn.name]();
                    console.log(`\nRESULT: ${res.toString()}`);
                } catch (e) {
                    console.error('ERROR:', e.reason || e.message);
                }
                rl.close();
            }
        });
    });
}

main();
