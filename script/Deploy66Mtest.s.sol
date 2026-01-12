// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/MainToken.sol";
import "../src/RewardsContract.sol";
import "../src/TokenLocker.sol";
import "../src/TokenTracker.sol";
import "../src/NFTTracker.sol";
import "../src/Randomizer.sol";

// Import NFTContract separately to avoid interface conflicts
import {NFTContract} from "../src/NFTContract.sol";

contract Deploy66Mtest is Script {
    // ============ WALLETS ============
    address constant WWMM = 0x0dFA1338E749A238B81569E9293B0b74782C446B;
    address constant TREASURWEE = 0x188b92F1cef56152D565c9740A5cd73936d1d090;
    address constant NFT_MINT_FUND = 0xDd77b7F08b60200D6FF15416774A8dE3bbb6B9f0;
    address constant TEAM_WALLET = 0x00aD851AbDe59d20DB72c7B2556e342CFca452E0;
    address constant SPILLAGE_WALLET = 0x009A4d69A28F4e8f0B10D09FBD1c4Cf084aCe5B8;
    address constant DEAD_WALLET = 0x000000000000000000000000000000000000dEaD;
    address constant RAILWAY_EXECUTOR = 0x190265ad8B8C846c7830dE7B91Eff126B8FfcD05;

    // ============ BASE MAINNET ============
    address constant UNISWAP_V2_ROUTER = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant SOL = 0x311935Cd80B76769bF2ecC9D8Ab7635b2139cf82;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant PYTH = 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a;

    // ============ CONFIG ============
    uint256 constant TOTAL_SUPPLY = 1_000_000_000 * 10**18;
    string constant NFT_BASE_URI = "ipfs://bafybeicu7rgkvagcy2rd6npdww5gd2iqhwwmsbnj32azw4jdcqf5rkayji/";

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);
        
        vm.startBroadcast(deployerPrivateKey);

        // ============ 1. DEPLOY MAIN TOKEN ============
        MainToken mainToken = new MainToken(WWMM, TOTAL_SUPPLY);
        console.log("MainToken deployed:", address(mainToken));

        // ============ 2. DEPLOY TOKEN TRACKER ============
        address[] memory excludedAddresses = new address[](5);
        excludedAddresses[0] = DEAD_WALLET;
        excludedAddresses[1] = deployer;
        excludedAddresses[2] = TEAM_WALLET;
        excludedAddresses[3] = SPILLAGE_WALLET;
        excludedAddresses[4] = address(mainToken);
        
        TokenTracker tokenTracker = new TokenTracker(
            address(mainToken),
            "66Mtest Tracker",
            "66MTT",
            excludedAddresses
        );
        console.log("TokenTracker deployed:", address(tokenTracker));

        // ============ 3. DEPLOY NFT TRACKER (needed for Rewards) ============
        NFTTracker nftTracker = new NFTTracker();
        console.log("NFTTracker deployed:", address(nftTracker));

        // ============ 4. DEPLOY REWARDS CONTRACT ============
        Rewards rewards = new Rewards(
            address(mainToken),
            address(nftTracker),
            address(tokenTracker),
            TREASURWEE,
            UNISWAP_V2_ROUTER
        );
        console.log("Rewards deployed:", address(rewards));

        // ============ 5. DEPLOY TOKEN LOCKER ============
        TokenLocker tokenLocker = new TokenLocker(address(mainToken));
        console.log("TokenLocker deployed:", address(tokenLocker));

        // ============ 6. DEPLOY NFT CONTRACT (with placeholder randomizer) ============
        NFTContract nftContract = new NFTContract(
            NFT_BASE_URI,
            address(mainToken),
            deployer, // Placeholder for randomizer - set later
            address(nftTracker),
            WETH,
            SOL,
            USDC,
            NFT_MINT_FUND,
            PYTH
        );
        console.log("NFTContract deployed:", address(nftContract));

        // ============ 7. DEPLOY RANDOMIZER (with NFT address) ============
        Randomizer randomizer = new Randomizer(address(nftContract));
        console.log("Randomizer deployed:", address(randomizer));

        // ============ LINK CONTRACTS ============
        console.log("\n--- Linking Contracts ---");

        // MainToken links
        mainToken.setTokenTracker(address(tokenTracker));
        mainToken.setRewardsContract(address(rewards));
        mainToken.setTokenLocker(address(tokenLocker));
        mainToken.setUniswapRouter(UNISWAP_V2_ROUTER);
        mainToken.excludeDefaultAddresses(DEAD_WALLET, deployer, TEAM_WALLET, SPILLAGE_WALLET);
        console.log("MainToken linked");

        // Rewards links
        rewards.addAllowedExecutor(RAILWAY_EXECUTOR);
        rewards.addAllowedExecutor(deployer); // For testing
        console.log("Rewards linked");

        // TokenTracker links
        tokenTracker.setRewardsContract(address(rewards));
        console.log("TokenTracker linked");

        // NFTTracker links
        nftTracker.setNFTContract(address(nftContract));
        nftTracker.setRewardsContract(address(rewards));
        console.log("NFTTracker linked");

        // NFTContract links - set the real randomizer
        nftContract.setRandomizer(address(randomizer));
        nftContract.setUniswapRouter(UNISWAP_V2_ROUTER);
        console.log("NFTContract linked");

        vm.stopBroadcast();

        // ============ SUMMARY ============
        console.log("\n========== DEPLOYMENT COMPLETE ==========");
        console.log("MainToken:      ", address(mainToken));
        console.log("TokenTracker:   ", address(tokenTracker));
        console.log("NFTTracker:     ", address(nftTracker));
        console.log("Rewards:        ", address(rewards));
        console.log("TokenLocker:    ", address(tokenLocker));
        console.log("NFTContract:    ", address(nftContract));
        console.log("Randomizer:     ", address(randomizer));
        console.log("\n========== NEXT STEPS ==========");
        console.log("1. Add LP to Uniswap (TOKEN/WETH pair)");
        console.log("2. Call mainToken.setIsUniswapPair(PAIR_ADDRESS, true)");
        console.log("3. Call mainToken.enableTrading()");
        console.log("4. Fund Railway executor with ETH for gas");
        console.log("5. Upload shuffled IDs to Randomizer");
    }
}
