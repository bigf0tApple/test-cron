// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {MainToken} from "../src/MainToken.sol";
import {TokenTracker} from "../src/TokenTracker.sol";
import {NFTTracker} from "../src/NFTTracker.sol";
import {NFTContract} from "../src/NFTContract.sol";
import {Randomizer} from "../src/Randomizer.sol";
import {RewardsContract} from "../src/RewardsContract.sol";
import {WWMMContractV3} from "../src/WWMMContractV3.sol";
import {TokenLocker} from "../src/TokenLocker.sol";
import {ARBContractV4} from "../src/ARBContractV4.sol";

/**
 * @title Deploy773me
 * @notice Full deployment script for 773me ecosystem
 * 
 * DEPLOYMENT ORDER (Dependencies):
 * 1. MainToken (773ME) - No dependencies
 * 2. TokenTracker - Needs MainToken
 * 3. NFTTracker - Needs MainToken
 * 4. Randomizer - No dependencies
 * 5. NFTContract - Needs Randomizer, NFTTracker, Pyth
 * 6. RewardsContract - Needs MainToken, NFTTracker, TokenTracker
 * 7. ARBContractV4 - Needs MainToken, Pyth (pools set later)
 * 8. WWMMContractV3 - Needs MainToken, ARBContract (pools set later)
 * 9. TokenLocker - Needs MainToken (receives 38.2M tokens)
 * 
 * RUN:
 * source .env && forge script script/Deploy773me.s.sol:Deploy773me --rpc-url $BASE_MAINNET_RPC --broadcast
 */
contract Deploy773me is Script {
    // ============ EXTERNAL CONTRACTS (Base Mainnet) ============
    address constant UNISWAP_V2_ROUTER = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
    address constant PANCAKE_V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant SOL = 0x311935Cd80B76769bF2ecC9D8Ab7635b2139cf82;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant PYTH = 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a;
    
    // V3 Pool for SOL/WETH price reference (PancakeSwap V3)
    address constant V3_POOL_SOL_WETH = 0xab07dE353E15b80fa3B4224D5C8fDF3Ac9F50670;
    
    // USDC pairs for NFT price fallback (if Pyth fails)
    address constant WETH_USDC_PAIR = 0x88A43bbDF9D098eEC7bCEda4e2494615dfD9bB9C; // Uniswap V2 WETH/USDC
    address constant SOL_USDC_PAIR = address(0); // TODO: Set if exists, else leave 0
    
    // ============ WALLETS ============
    address constant TREASURY = 0x188b92F1cef56152D565c9740A5cd73936d1d090;
    address constant NFT_MINT_FUND = 0xDd77b7F08b60200D6FF15416774A8dE3bbb6B9f0;
    address constant RAILWAY_EXECUTOR = 0x190265ad8B8C846c7830dE7B91Eff126B8FfcD05;
    address constant DEAD_WALLET = 0x000000000000000000000000000000000000dEaD;
    address constant DEPLOYER = 0x546b3B34A4B94C5a49F09eD6Bc1edD094A2637C7;
    
    // Team wallets (exclude from trackers - no rewards minting to these)
    address constant DEV_WALLET = 0x77b1fBe87487eBB0e47Da8198dACf41c32827fC6;
    address constant CORE_WALLET = 0x00aD851AbDe59d20DB72c7B2556e342CFca452E0;
    address constant SPILLAGE_WALLET = 0x009A4d69A28F4e8f0B10D09FBD1c4Cf084aCe5B8;
    address constant FREE_WEE_WALLET = 0xaeE5f3144A24177937Ba525C606f5899043923E4;
    
    // ============ NFT CONFIG ============
    string constant NFT_BASE_URI = "ipfs://bafybeicu7rgkvagcy2rd6npdww5gd2iqhwwmsbnj32azw4jdcqf5rkayji/";
    
    // ============ DEPLOYED ADDRESSES (filled during deployment) ============
    MainToken public mainToken;
    TokenTracker public tokenTracker;
    NFTTracker public nftTracker;
    Randomizer public randomizer;
    NFTContract public nftContract;
    RewardsContract public rewardsContract;
    ARBContractV4 public arbContract;
    WWMMContractV3 public wwmmContract;
    TokenLocker public tokenLocker;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("============================================");
        console.log("   773me ECOSYSTEM DEPLOYMENT");
        console.log("============================================");
        console.log("Deployer:", deployer);
        console.log("Chain: Base Mainnet (8453)");
        console.log("");
        
        vm.startBroadcast(deployerPrivateKey);

        // ========================================
        // STEP 1: Deploy MainToken (773ME)
        // ========================================
        console.log("[1/9] Deploying MainToken (773ME)...");
        mainToken = new MainToken(UNISWAP_V2_ROUTER);
        console.log("      MainToken:", address(mainToken));
        console.log("      Deployer received: 618M 773ME");
        console.log("      Contract holds: 382M 773ME (for TokenLocker)");
        
        // ========================================
        // STEP 2: Deploy TokenTracker
        // ========================================
        console.log("[2/9] Deploying TokenTracker...");
        address[] memory excludedAddrs = new address[](3);
        excludedAddrs[0] = address(0); // Will be WWMM
        excludedAddrs[1] = address(0); // Will be ARB
        excludedAddrs[2] = address(0); // Will be TokenLocker
        tokenTracker = new TokenTracker(
            address(mainToken),
            "773me Holders",
            "773MEH",
            excludedAddrs
        );
        console.log("      TokenTracker:", address(tokenTracker));
        
        // ========================================
        // STEP 3: Deploy NFTTracker
        // ========================================
        console.log("[3/9] Deploying NFTTracker...");
        nftTracker = new NFTTracker(); // No constructor args, uses setNFTContract later
        console.log("      NFTTracker:", address(nftTracker));
        
        // ========================================
        // STEP 4: Deploy Randomizer
        // ========================================
        console.log("[4/9] Deploying Randomizer...");
        randomizer = new Randomizer(address(0)); // NFT address set after deployment
        console.log("      Randomizer:", address(randomizer));
        
        // ========================================
        // STEP 5: Deploy NFTContract (773me Drops)
        // ========================================
        console.log("[5/9] Deploying NFTContract (773me Drops)...");
        nftContract = new NFTContract(
            NFT_BASE_URI,
            address(mainToken),
            address(randomizer),
            address(nftTracker),
            USDC,
            NFT_MINT_FUND
        );
        console.log("      NFTContract:", address(nftContract));
        
        // Link Randomizer to NFT
        randomizer.setNftContract(address(nftContract));
        
        // ========================================
        // STEP 6: Deploy RewardsContract
        // ========================================
        console.log("[6/9] Deploying RewardsContract...");
        rewardsContract = new RewardsContract(
            address(mainToken),
            address(nftTracker),
            address(tokenTracker),
            TREASURY,
            UNISWAP_V2_ROUTER
        );
        console.log("      RewardsContract:", address(rewardsContract));
        
        // ========================================
        // STEP 7: Deploy ARBContractV4
        // ========================================
        console.log("[7/9] Deploying ARBContractV4...");
        arbContract = new ARBContractV4(
            address(mainToken),
            UNISWAP_V2_ROUTER,
            PANCAKE_V3_ROUTER,
            V3_POOL_SOL_WETH  // SOL/WETH V3 pool for price reference
        );
        console.log("      ARBContract:", address(arbContract));
        
        // ========================================
        // STEP 8: Deploy WWMMContractV3
        // ========================================
        console.log("[8/9] Deploying WWMMContractV3...");
        wwmmContract = new WWMMContractV3(
            address(mainToken),
            address(arbContract),
            address(0), // poolA - set after pools created
            address(0), // poolB - set after pools created
            WETH,
            SOL
        );
        console.log("      WWMMContract:", address(wwmmContract));
        
        // ========================================
        // STEP 9: Deploy TokenLocker
        // ========================================
        console.log("[9/9] Deploying TokenLocker...");
        tokenLocker = new TokenLocker(address(mainToken));
        console.log("      TokenLocker:", address(tokenLocker));
        
        // ========================================
        // CONFIGURE CROSS-REFERENCES
        // ========================================
        console.log("");
        console.log("Configuring cross-references...");
        
        // MainToken configuration
        mainToken.setWwmmContract(address(wwmmContract));
        mainToken.setArbContract(address(arbContract));
        mainToken.setRewardsContract(address(rewardsContract));
        mainToken.setTokenTracker(address(tokenTracker));
        mainToken.setTokenLocker(address(tokenLocker)); // Transfers 382M to locker
        // CRITICAL: ARB must be tax exempt to avoid feedback loop
        mainToken.setExcludedFromTax(address(arbContract), true);
        console.log("      MainToken configured (382M sent to TokenLocker, ARB tax exempt)");
        
        // ARB configuration
        arbContract.setWWMM(address(wwmmContract));
        arbContract.setNFTContract(address(nftContract));
        arbContract.setTokenAddresses(WETH, SOL);
        console.log("      ARBContract configured");
        
        // NFTTracker configuration
        nftTracker.setNFTContract(address(nftContract));
        nftTracker.setRewardsContract(address(rewardsContract));
        // Exclude ALL system addresses + team wallets from NFT tracker (no minting)
        nftTracker.setExcludedAddress(DEAD_WALLET, true);
        nftTracker.setExcludedAddress(DEPLOYER, true);
        nftTracker.setExcludedAddress(TREASURY, true);
        nftTracker.setExcludedAddress(NFT_MINT_FUND, true);
        nftTracker.setExcludedAddress(DEV_WALLET, true);
        nftTracker.setExcludedAddress(CORE_WALLET, true);
        nftTracker.setExcludedAddress(SPILLAGE_WALLET, true);
        nftTracker.setExcludedAddress(FREE_WEE_WALLET, true);
        nftTracker.setExcludedAddress(address(mainToken), true);
        nftTracker.setExcludedAddress(address(tokenTracker), true);
        nftTracker.setExcludedAddress(address(wwmmContract), true);
        nftTracker.setExcludedAddress(address(arbContract), true);
        nftTracker.setExcludedAddress(address(rewardsContract), true);
        nftTracker.setExcludedAddress(address(tokenLocker), true);
        nftTracker.setExcludedAddress(address(nftContract), true);
        nftTracker.setExcludedAddress(address(randomizer), true);
        console.log("      NFTTracker configured + 16 addresses excluded (no minting)");
        
        // TokenTracker configuration - exclude ALL system addresses + team wallets (no minting)
        tokenTracker.setRewardsContract(address(rewardsContract));
        tokenTracker.setExcludedAddress(DEAD_WALLET, true);
        tokenTracker.setExcludedAddress(DEPLOYER, true);
        tokenTracker.setExcludedAddress(TREASURY, true);
        tokenTracker.setExcludedAddress(NFT_MINT_FUND, true);
        tokenTracker.setExcludedAddress(DEV_WALLET, true);
        tokenTracker.setExcludedAddress(CORE_WALLET, true);
        tokenTracker.setExcludedAddress(SPILLAGE_WALLET, true);
        tokenTracker.setExcludedAddress(FREE_WEE_WALLET, true);
        tokenTracker.setExcludedAddress(address(mainToken), true);
        tokenTracker.setExcludedAddress(address(nftTracker), true);
        tokenTracker.setExcludedAddress(address(wwmmContract), true);
        tokenTracker.setExcludedAddress(address(arbContract), true);
        tokenTracker.setExcludedAddress(address(tokenLocker), true);
        tokenTracker.setExcludedAddress(address(rewardsContract), true);
        tokenTracker.setExcludedAddress(address(nftContract), true);
        tokenTracker.setExcludedAddress(address(randomizer), true);
        console.log("      TokenTracker configured + 16 addresses excluded (no minting)");
        
        // Rewards configuration
        rewardsContract.addAllowedExecutor(RAILWAY_EXECUTOR);
        console.log("      RewardsContract configured");
        
        // NFTContract configuration
        // NOTE: setUniswapRouter not needed - NFT minting uses direct token transfers
        nftContract.setTokenLocker(address(tokenLocker));
        console.log("      NFTContract configured");
        
        vm.stopBroadcast();
        
        // ========================================
        // PRINT SUMMARY
        // ========================================
        console.log("");
        console.log("============================================");
        console.log("   DEPLOYMENT COMPLETE!");
        console.log("============================================");
        console.log("");
        console.log("# Add to .env:");
        console.log("MAIN_TOKEN=", address(mainToken));
        console.log("TOKEN_TRACKER=", address(tokenTracker));
        console.log("NFT_TRACKER=", address(nftTracker));
        console.log("RANDOMIZER=", address(randomizer));
        console.log("NFT_CONTRACT=", address(nftContract));
        console.log("REWARDS_CONTRACT=", address(rewardsContract));
        console.log("ARB_CONTRACT=", address(arbContract));
        console.log("WWMM_CONTRACT=", address(wwmmContract));
        console.log("TOKEN_LOCKER=", address(tokenLocker));
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Create 773ME/WETH and 773ME/SOL pools on Uniswap");
        console.log("2. Call arbContract.setPools() and wwmmContract.setPools()");
        console.log("3. Add pool addresses to tracker exclusions");
        console.log("4. Call mainToken.enableTrading()");
        console.log("5. Upload shuffled IDs to Randomizer");
        console.log("6. Test buy/sell and verify arb triggers");
    }
}

/**
 * @title ConfigurePools
 * @notice Run AFTER creating LP pools to set pool addresses
 * 
 * RUN:
 * source .env && forge script script/Deploy773me.s.sol:ConfigurePools --rpc-url $BASE_MAINNET_RPC --broadcast
 */
contract ConfigurePools is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        
        // These will be filled after LP creation
        address payable mainTokenAddr = payable(vm.envAddress("MAIN_TOKEN"));
        address payable arbContractAddr = payable(vm.envAddress("ARB_CONTRACT"));
        address payable wwmmContractAddr = payable(vm.envAddress("WWMM_CONTRACT"));
        address payable nftContractAddr = payable(vm.envAddress("NFT_CONTRACT"));
        address poolWeth = vm.envAddress("POOL_773ME_WETH");
        address poolSol = vm.envAddress("POOL_773ME_SOL");
        
        console.log("Configuring pools...");
        console.log("773ME/WETH Pool:", poolWeth);
        console.log("773ME/SOL Pool:", poolSol);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Set pools in MainToken
        MainToken(mainTokenAddr).setIsUniswapPair(poolWeth, true);
        MainToken(mainTokenAddr).setIsUniswapPair(poolSol, true);
        MainToken(mainTokenAddr).setWethPair(poolWeth);
        
        // Set pools in ARB
        ARBContractV4(arbContractAddr).setPools(poolWeth, poolSol);
        
        // Set pools in WWMM
        WWMMContractV3(wwmmContractAddr).setPools(poolWeth, poolSol);
        
        vm.stopBroadcast();
        
        console.log("Pools configured!");
        console.log("Next: Call mainToken.enableTrading()");
    }
}
