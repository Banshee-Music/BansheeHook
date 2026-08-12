// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    Test
} from "forge-std/Test.sol";


import {
    BansheeHook
} from "../src/BansheeHook.sol";


import {
    IPoolManager
} from
    "@uniswap/v4-core/src/interfaces/IPoolManager.sol";


import {
    PoolKey
} from
    "@uniswap/v4-core/src/types/PoolKey.sol";


import {
    Currency
} from
    "@uniswap/v4-core/src/types/Currency.sol";


import {
    IHooks
} from
    "@uniswap/v4-core/src/interfaces/IHooks.sol";


import {
    ERC20
} from
    "@openzeppelin/contracts/token/ERC20/ERC20.sol";


import {
    ERC1155
} from
    "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";


// ============================================================
// MOCK ERC20
// ============================================================

contract MockUSDC is ERC20 {

    constructor()
        ERC20(
            "Mock USD Coin",
            "mUSDC"
        )
    {}


    function mint(
        address to,
        uint256 amount
    )
        external
    {
        _mint(
            to,
            amount
        );
    }
}


// ============================================================
// MOCK MARKET TOKEN
// ============================================================

contract MockMarketToken is ERC20 {

    constructor()
        ERC20(
            "Banshee Market Asset",
            "BMA"
        )
    {}


    function mint(
        address to,
        uint256 amount
    )
        external
    {
        _mint(
            to,
            amount
        );
    }
}


// ============================================================
// MOCK ERC1155
// ============================================================

contract MockBanshee1155 is ERC1155 {

    constructor()
        ERC1155(
            "https://greenfield.banshee/metadata/{id}.json"
        )
    {}


    function mint(
        address to,
        uint256 tokenId,
        uint256 amount
    )
        external
    {
        _mint(
            to,
            tokenId,
            amount,
            ""
        );
    }
}


// ============================================================
// CREATE2 FACTORY
// ============================================================

contract TestHookFactory {

    error DeploymentFailed();


    function deploy(
        bytes memory creationCode,
        bytes32 salt
    )
        external
        returns (
            address deployed
        )
    {
        assembly {

            deployed :=
                create2(
                    0,
                    add(
                        creationCode,
                        0x20
                    ),
                    mload(
                        creationCode
                    ),
                    salt
                )
        }


        if (
            deployed ==
            address(0)
        ) {
            revert DeploymentFailed();
        }
    }
}


// ============================================================
// BANSHEE HOOK TEST
// ============================================================

contract BansheeHookTest is Test {

    // ========================================================
    // UNISWAP HOOK FLAGS
    // ========================================================

    uint160 internal constant BEFORE_SWAP_FLAG =
        1 << 7;

    uint160 internal constant AFTER_SWAP_FLAG =
        1 << 6;

    uint160 internal constant REQUIRED_FLAGS =
        BEFORE_SWAP_FLAG |
        AFTER_SWAP_FLAG;

    uint160 internal constant ALL_HOOK_MASK =
        (1 << 14) - 1;


    // ========================================================
    // TEST ADDRESSES
    // ========================================================

    address internal owner =
        address(0xA11CE);

    address internal agent =
        address(0xBADA55);

    address internal treasury =
        address(0x7777);

    address internal artist =
        address(0xA47157);

    address internal buyer =
        address(0xB0B);

    address internal attacker =
        address(0xBAD);


    // ========================================================
    // CONTRACTS
    // ========================================================

    BansheeHook internal hook;

    MockUSDC internal usdc;

    MockMarketToken internal marketToken;

    MockBanshee1155 internal music;


    /**
     * For these unit tests the PoolManager itself
     * does not need to execute swaps.
     *
     * We only need a non-zero PoolManager address
     * for BaseHook construction and launch registration.
     */
    IPoolManager internal poolManager;


    // ========================================================
    // POOL
    // ========================================================

    PoolKey internal poolKey;


    // ========================================================
    // LAUNCH CONFIG
    // ========================================================

    uint256 internal constant TOKEN_ID =
        1;

    uint256 internal constant SUPPLY =
        1_000;

    uint256 internal constant PRICE =
        10 ether;

    uint16 internal constant PROTOCOL_FEE =
        500;

    uint16 internal constant ROYALTY_FEE =
        1_000;

    uint64 internal startTime;

    uint64 internal fairLaunchEnd;


    // ========================================================
    // SETUP
    // ========================================================

    function setUp()
        public
    {

        // ----------------------------------------------------
        // Mock contracts
        // ----------------------------------------------------

        usdc =
            new MockUSDC();


        marketToken =
            new MockMarketToken();


        music =
            new MockBanshee1155();


        // ----------------------------------------------------
        // Mock PoolManager address
        // ----------------------------------------------------

        poolManager =
            IPoolManager(
                address(
                    0x123456
                )
            );


        // ----------------------------------------------------
        // Deploy hook with valid permission bits
        // ----------------------------------------------------

        hook =
            _deployHook();


        // ----------------------------------------------------
        // Configure PoolKey
        // ----------------------------------------------------

        Currency currencyA =
            Currency.wrap(
                address(
                    marketToken
                )
            );


        Currency currencyB =
            Currency.wrap(
                address(
                    usdc
                )
            );


        /*
            Currency ordering isn't important for these
            unit tests because the PoolManager isn't being
            initialized.

            For production pool initialization,
            currency0 < currency1 must be respected.
        */

        poolKey =
            PoolKey({
                currency0:
                    currencyA,

                currency1:
                    currencyB,

                fee:
                    3000,

                tickSpacing:
                    60,

                hooks:
                    IHooks(
                        address(
                            hook
                        )
                    )
            });


        // ----------------------------------------------------
        // Launch timing
        // ----------------------------------------------------

        startTime =
            uint64(
                block.timestamp
            );


        fairLaunchEnd =
            uint64(
                block.timestamp +
                1 hours
            );


        // ----------------------------------------------------
        // Give artist ERC1155 inventory
        // ----------------------------------------------------

        music.mint(
            artist,
            TOKEN_ID,
            SUPPLY
        );


        // ----------------------------------------------------
        // Artist approves BansheeHook
        // ----------------------------------------------------

        vm.prank(
            artist
        );

        music.setApprovalForAll(
            address(
                hook
            ),
            true
        );


        // ----------------------------------------------------
        // Fund buyer
        // ----------------------------------------------------

        usdc.mint(
            buyer,
            1_000_000 ether
        );


        vm.prank(
            buyer
        );

        usdc.approve(
            address(
                hook
            ),
            type(uint256).max
        );
    }


    // ========================================================
    // TEST HOOK DEPLOYMENT
    // ========================================================

    function testHookHasCorrectPermissionBits()
        public
        view
    {
        uint160 flags =
            uint160(
                address(
                    hook
                )
            )
            &
            ALL_HOOK_MASK;


        assertEq(
            flags,
            REQUIRED_FLAGS
        );
    }


    // ========================================================
    // CREATE LAUNCH
    // ========================================================

    function testAgentCanCreateLaunch()
        public
    {
        uint256 launchId =
            _createLaunch();


        assertEq(
            launchId,
            1
        );


        BansheeHook.Launch memory launch =
            hook.getLaunch(
                launchId
            );


        assertEq(
            launch.artist,
            artist
        );


        assertEq(
            launch.asset,
            address(
                music
            )
        );


        assertEq(
            launch.tokenId,
            TOKEN_ID
        );


        assertEq(
            launch.supply,
            SUPPLY
        );


        assertEq(
            launch.sold,
            0
        );


        assertEq(
            launch.launchPrice,
            PRICE
        );


        assertEq(
            uint256(
                launch.state
            ),
            uint256(
                BansheeHook
                    .LaunchState
                    .FAIR_LAUNCH
            )
        );


        /*
            Entire inventory should now
            be escrowed by the Hook.
        */
        assertEq(
            music.balanceOf(
                address(
                    hook
                ),
                TOKEN_ID
            ),
            SUPPLY
        );


        assertEq(
            music.balanceOf(
                artist,
                TOKEN_ID
            ),
            0
        );
    }


    // ========================================================
    // ONLY AI AGENT
    // ========================================================

    function testNonAgentCannotCreateLaunch()
        public
    {
        vm.prank(
            attacker
        );


        vm.expectRevert(
            BansheeHook
                .OnlyBansheeAgent
                .selector
        );


        hook.createLaunch(
            poolKey,

            artist,

            address(
                music
            ),

            TOKEN_ID,

            address(
                marketToken
            ),

            address(
                usdc
            ),

            BansheeHook
                .AssetType
                .SONG,

            SUPPLY,

            PRICE,

            startTime,

            fairLaunchEnd,

            PROTOCOL_FEE,

            ROYALTY_FEE
        );
    }


    // ========================================================
    // FAIR LAUNCH PURCHASE
    // ========================================================

    function testBuyerCanPurchaseDuringFairLaunch()
        public
    {
        uint256 launchId =
            _createLaunch();


        uint256 quantity =
            2;


        uint256 totalCost =
            PRICE *
            quantity;


        uint256 protocolFee =
            (
                totalCost *
                PROTOCOL_FEE
            )
            /
            10_000;


        uint256 artistAmount =
            totalCost -
            protocolFee;


        uint256 buyerBefore =
            usdc.balanceOf(
                buyer
            );


        vm.prank(
            buyer
        );


        hook.buy(
            launchId,
            quantity
        );


        // ----------------------------------------------------
        // Buyer receives ERC1155
        // ----------------------------------------------------

        assertEq(
            music.balanceOf(
                buyer,
                TOKEN_ID
            ),
            quantity
        );


        // ----------------------------------------------------
        // USDC deducted
        // ----------------------------------------------------

        assertEq(
            usdc.balanceOf(
                buyer
            ),
            buyerBefore -
            totalCost
        );


        // ----------------------------------------------------
        // Artist earnings
        // ----------------------------------------------------

        assertEq(
            hook.artistEarnings(
                launchId
            ),
            artistAmount
        );


        // ----------------------------------------------------
        // Protocol fees
        // ----------------------------------------------------

        assertEq(
            hook.protocolFees(
                address(
                    usdc
                )
            ),
            protocolFee
        );


        // ----------------------------------------------------
        // Launch counters
        // ----------------------------------------------------

        BansheeHook.Launch memory launch =
            hook.getLaunch(
                launchId
            );


        assertEq(
            launch.sold,
            quantity
        );


        assertEq(
            hook.remainingSupply(
                launchId
            ),
            SUPPLY -
            quantity
        );
    }


    // ========================================================
    // FIXED PRICE
    // ========================================================

    function testFairLaunchCost()
        public
    {
        uint256 launchId =
            _createLaunch();


        uint256 quantity =
            5;


        assertEq(
            hook.fairLaunchCost(
                launchId,
                quantity
            ),
            PRICE *
            quantity
        );
    }


    // ========================================================
    // SALE ENDS
    // ========================================================

    function testCannotBuyAfterFairLaunch()
        public
    {
        uint256 launchId =
            _createLaunch();


        vm.warp(
            fairLaunchEnd
        );


        vm.prank(
            buyer
        );


        vm.expectRevert(
            BansheeHook
                .FairLaunchEnded
                .selector
        );


        hook.buy(
            launchId,
            1
        );
    }


    // ========================================================
    // ACTIVATE OPEN MARKET
    // ========================================================

    function testMarketActivatesAfterFairLaunch()
        public
    {
        uint256 launchId =
            _createLaunch();


        vm.warp(
            fairLaunchEnd
        );


        hook.activateMarket(
            launchId
        );


        BansheeHook.Launch memory launch =
            hook.getLaunch(
                launchId
            );


        assertEq(
            uint256(
                launch.state
            ),
            uint256(
                BansheeHook
                    .LaunchState
                    .ACTIVE
            )
        );
    }


    // ========================================================
    // ARTIST CLAIM
    // ========================================================

    function testArtistCanClaimPrimarySaleRevenue()
        public
    {
        uint256 launchId =
            _createLaunch();


        uint256 quantity =
            10;


        vm.prank(
            buyer
        );


        hook.buy(
            launchId,
            quantity
        );


        uint256 earnings =
            hook.artistEarnings(
                launchId
            );


        uint256 beforeBalance =
            usdc.balanceOf(
                artist
            );


        vm.prank(
            artist
        );


        hook.claimArtistEarnings(
            launchId
        );


        assertEq(
            usdc.balanceOf(
                artist
            ),
            beforeBalance +
            earnings
        );


        assertEq(
            hook.artistEarnings(
                launchId
            ),
            0
        );
    }


    // ========================================================
    // NON-ARTIST CANNOT CLAIM
    // ========================================================

    function testNonArtistCannotClaimEarnings()
        public
    {
        uint256 launchId =
            _createLaunch();


        vm.prank(
            buyer
        );


        hook.buy(
            launchId,
            1
        );


        vm.prank(
            attacker
        );


        vm.expectRevert(
            BansheeHook
                .NotArtist
                .selector
        );


        hook.claimArtistEarnings(
            launchId
        );
    }


    // ========================================================
    // ROYALTY DEPOSIT
    // ========================================================

    function testSecondaryRoyaltyCanBeDeposited()
        public
    {
        uint256 launchId =
            _createLaunch();


        address royaltyCollector =
            address(
                0xCAFE
            );


        uint256 royaltyAmount =
            50 ether;


        usdc.mint(
            royaltyCollector,
            royaltyAmount
        );


        vm.prank(
            royaltyCollector
        );


        usdc.approve(
            address(
                hook
            ),
            royaltyAmount
        );


        vm.prank(
            royaltyCollector
        );


        hook.depositRoyalty(
            launchId,
            royaltyAmount
        );


        assertEq(
            hook.artistEarnings(
                launchId
            ),
            royaltyAmount
        );
    }


    // ========================================================
    // UNSOLD INVENTORY
    // ========================================================

    function testArtistCanWithdrawUnsoldInventory()
        public
    {
        uint256 launchId =
            _createLaunch();


        vm.prank(
            buyer
        );


        hook.buy(
            launchId,
            100
        );


        vm.warp(
            fairLaunchEnd
        );


        uint256 expectedUnsold =
            900;


        vm.prank(
            artist
        );


        hook.withdrawUnsoldInventory(
            launchId
        );


        assertEq(
            music.balanceOf(
                artist,
                TOKEN_ID
            ),
            expectedUnsold
        );


        assertEq(
            music.balanceOf(
                address(
                    hook
                ),
                TOKEN_ID
            ),
            0
        );
    }


    // ========================================================
    // END LAUNCH
    // ========================================================

    function testArtistCanEndLaunch()
        public
    {
        uint256 launchId =
            _createLaunch();


        vm.prank(
            artist
        );


        hook.endLaunch(
            launchId
        );


        BansheeHook.Launch memory launch =
            hook.getLaunch(
                launchId
            );


        assertEq(
            uint256(
                launch.state
            ),
            uint256(
                BansheeHook
                    .LaunchState
                    .ENDED
            )
        );
    }


    // ========================================================
    // HELPER — CREATE LAUNCH
    // ========================================================

    function _createLaunch()
        internal
        returns (
            uint256 launchId
        )
    {
        vm.prank(
            agent
        );


        launchId =
            hook.createLaunch(
                poolKey,

                artist,

                address(
                    music
                ),

                TOKEN_ID,

                address(
                    marketToken
                ),

                address(
                    usdc
                ),

                BansheeHook
                    .AssetType
                    .SONG,

                SUPPLY,

                PRICE,

                startTime,

                fairLaunchEnd,

                PROTOCOL_FEE,

                ROYALTY_FEE
            );
    }


    // ========================================================
    // HELPER — DEPLOY VALID HOOK
    // ========================================================

    function _deployHook()
        internal
        returns (
            BansheeHook deployedHook
        )
    {
        TestHookFactory factory =
            new TestHookFactory();


        bytes memory creationCode =
            abi.encodePacked(
                type(
                    BansheeHook
                ).creationCode,

                abi.encode(
                    poolManager,

                    owner,

                    agent,

                    treasury
                )
            );


        bytes32 initCodeHash =
            keccak256(
                creationCode
            );


        bytes32 salt;

        address predicted;


        for (
            uint256 i = 0;
            ;
            ++i
        ) {

            salt =
                bytes32(i);


            predicted =
                address(
                    uint160(
                        uint256(
                            keccak256(
                                abi.encodePacked(
                                    bytes1(
                                        0xff
                                    ),

                                    address(
                                        factory
                                    ),

                                    salt,

                                    initCodeHash
                                )
                            )
                        )
                    )
                );


            if (
                (
                    uint160(
                        predicted
                    )
                    &
                    ALL_HOOK_MASK
                )
                ==
                REQUIRED_FLAGS
            ) {
                break;
            }
        }


        address deployed =
            factory.deploy(
                creationCode,
                salt
            );


        assertEq(
            deployed,
            predicted
        );


        deployedHook =
            BansheeHook(
                payable(
                    deployed
                )
            );
    }
}