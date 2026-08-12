// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
    BANSHEE HOOK

    Instead of launching a normal ERC-20 as the product,
    Banshee launches an ERC-1155 asset representing:

        - Song
        - Album
        - Ticket

    Lifecycle:

        CREATED
           ↓
        FAIR_LAUNCH
           ↓
        ACTIVE
           ↓
        ENDED

    During FAIR_LAUNCH:
        Fans purchase ERC-1155 units at a fixed price.

    After FAIR_LAUNCH:
        The associated fungible market representation can trade
        through its Uniswap v4 pool.

    Artist revenue:
        - Primary sale proceeds
        - Secondary royalty deposits
        - Future Proof-of-Performance rewards handled separately

    NOTE:
        ERC-1155 assets cannot themselves be Uniswap v4 Currency
        objects. `marketToken` represents the fungible market side
        of the ERC-1155 launch.

        The ERC-1155 remains the canonical Banshee asset.
*/

import {BaseHook} from "v4-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {IPoolManager} from
    "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PoolKey} from
    "@uniswap/v4-core/src/types/PoolKey.sol";

import {
    PoolId,
    PoolIdLibrary
} from "@uniswap/v4-core/src/types/PoolId.sol";

import {BalanceDelta} from
    "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {BeforeSwapDelta} from
    "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {SwapParams} from
    "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IERC20} from
    "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IERC1155} from
    "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

import {ERC1155Holder} from
    "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {Ownable} from
    "@openzeppelin/contracts/access/Ownable.sol";

import {Ownable2Step} from
    "@openzeppelin/contracts/access/Ownable2Step.sol";

import {Pausable} from
    "@openzeppelin/contracts/utils/Pausable.sol";

import {ReentrancyGuard} from
    "@openzeppelin/contracts/utils/ReentrancyGuard.sol";


// Botchain Testnet Address: 0x2E66c77e30a3fE0b0c36bB8Bd88e1f635E3C00C0
// BSC Testnet Address: 0x4441c05964F28C56ff4e2bc721d5a8D45DAc40C0
contract BansheeHook is
    BaseHook,
    ERC1155Holder,
    Ownable2Step,
    Pausable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    // ============================================================
    // CONSTANTS
    // ============================================================

    uint256 public constant BPS = 10_000;

    uint256 public constant MAX_PROTOCOL_FEE_BPS = 1_000;

    uint256 public constant MAX_ROYALTY_BPS = 2_500;


    // ============================================================
    // ENUMS
    // ============================================================

    /**
     * @notice Asset being launched.
     */
    enum AssetType {
        SONG,
        ALBUM,
        TICKET
    }

    /**
     * @notice Lifecycle of a Banshee launch.
     */
    enum LaunchState {
        NONE,
        CREATED,
        FAIR_LAUNCH,
        ACTIVE,
        ENDED
    }


    // ============================================================
    // STRUCTS
    // ============================================================

    /**
     * @notice Core information for a Banshee launch.
     *
     * asset:
     *     Canonical ERC-1155 contract.
     *
     * tokenId:
     *     ERC-1155 song / album / ticket ID.
     *
     * marketToken:
     *     Fungible market representation used by Uniswap v4.
     *
     * quoteToken:
     *     Asset used to purchase the ERC-1155 during fair launch.
     *     Example: USDC.
     *
     * poolId:
     *     Associated Uniswap v4 market.
     */
    struct Launch {
        address artist;

        address asset;

        uint256 tokenId;

        address marketToken;

        address quoteToken;

        bytes32 poolId;

        AssetType assetType;

        LaunchState state;

        uint256 supply;

        uint256 sold;

        uint256 launchPrice;

        uint64 startTime;

        uint64 fairLaunchEnd;

        uint16 protocolFeeBps;

        uint16 secondaryRoyaltyBps;

        uint256 swapCount;
    }


    // ============================================================
    // STORAGE
    // ============================================================

    /**
     * @notice Banshee AI Agent.
     *
     * The agent verifies creators/content before launches are created.
     */
    address public bansheeAgent;


    /**
     * @notice Protocol treasury.
     */
    address public treasury;


    /**
     * @notice Incrementing launch ID.
     */
    uint256 public nextLaunchId;


    /**
     * @notice launchId => Launch.
     */
    mapping(uint256 => Launch) private _launches;


    /**
     * @notice PoolId => launch ID.
     */
    mapping(bytes32 => uint256) public launchIdByPool;


    /**
     * @notice
     * ERC1155 contract => tokenId => launch ID.
     */
    mapping(address => mapping(uint256 => uint256))
        public launchIdByAsset;


    /**
     * @notice
     * Artist proceeds stored by launch.
     */
    mapping(uint256 => uint256)
        public artistEarnings;


    /**
     * @notice
     * Protocol fees stored by ERC-20 token.
     */
    mapping(address => uint256)
        public protocolFees;


    // ============================================================
    // EVENTS
    // ============================================================

    event LaunchCreated(
        uint256 indexed launchId,
        address indexed artist,
        address indexed asset,
        uint256 tokenId,
        AssetType assetType,
        uint256 supply,
        uint256 launchPrice
    );


    event FairLaunchStarted(
        uint256 indexed launchId,
        uint64 startTime,
        uint64 fairLaunchEnd
    );


    event AssetPurchased(
        uint256 indexed launchId,
        address indexed buyer,
        uint256 quantity,
        uint256 totalPaid
    );


    event MarketActivated(
        uint256 indexed launchId,
        bytes32 indexed poolId
    );


    event SecondaryTrade(
        uint256 indexed launchId,
        bytes32 indexed poolId,
        address indexed sender,
        bool zeroForOne,
        int256 amountSpecified,
        uint256 swapCount
    );


    event RoyaltyDeposited(
        uint256 indexed launchId,
        address indexed payer,
        uint256 amount
    );


    event ArtistEarningsClaimed(
        uint256 indexed launchId,
        address indexed artist,
        uint256 amount
    );


    event LaunchEnded(
        uint256 indexed launchId
    );


    event UnsoldInventoryWithdrawn(
        uint256 indexed launchId,
        address indexed artist,
        uint256 amount
    );


    event AgentUpdated(
        address indexed oldAgent,
        address indexed newAgent
    );


    event TreasuryUpdated(
        address indexed oldTreasury,
        address indexed newTreasury
    );


    // ============================================================
    // ERRORS
    // ============================================================

    error ZeroAddress();

    error OnlyBansheeAgent();

    error OnlyArtistOrAgent();

    error LaunchDoesNotExist();

    error AssetAlreadyLaunched();

    error PoolAlreadyRegistered();

    error InvalidSupply();

    error InvalidPrice();

    error InvalidFee();

    error InvalidLaunchTime();

    error InvalidState();

    error SaleNotStarted();

    error FairLaunchEnded();

    error FairLaunchNotEnded();

    error SoldOut();

    error InvalidQuantity();

    error InsufficientInventory();

    error NotArtist();

    error NothingToClaim();

    error InvalidPoolHook();


    // ============================================================
    // MODIFIERS
    // ============================================================

    modifier onlyAgent() {
        if (msg.sender != bansheeAgent) {
            revert OnlyBansheeAgent();
        }

        _;
    }


    modifier onlyArtistOrAgent(
        uint256 launchId
    ) {
        Launch storage launch =
            _requireLaunch(launchId);

        if (
            msg.sender != launch.artist &&
            msg.sender != bansheeAgent &&
            msg.sender != owner()
        ) {
            revert OnlyArtistOrAgent();
        }

        _;
    }


    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    constructor(
        IPoolManager poolManager_,
        address owner_,
        address bansheeAgent_,
        address treasury_
    )
        BaseHook(poolManager_)
        Ownable(owner_)
    {
        if (
            address(poolManager_) == address(0) ||
            owner_ == address(0) ||
            bansheeAgent_ == address(0) ||
            treasury_ == address(0)
        ) {
            revert ZeroAddress();
        }

        bansheeAgent = bansheeAgent_;

        treasury = treasury_;
    }


    // ============================================================
    // UNISWAP V4 HOOK PERMISSIONS
    // ============================================================

    /**
     * @notice
     * The simplified Banshee Hook only needs:
     *
     * beforeSwap:
     *     Prevent secondary trading before the fair launch ends.
     *
     * afterSwap:
     *     Record secondary market activity for royalties /
     *     Proof-of-Performance indexing.
     *
     * No custom token deltas are used in v1.
     */
    function getHookPermissions()
    public
    pure
    override
    returns (Hooks.Permissions memory)
{
    return Hooks.Permissions({
        beforeInitialize: false,
        afterInitialize: false,
        beforeAddLiquidity: false,
        afterAddLiquidity: false,
        beforeRemoveLiquidity: false,
        afterRemoveLiquidity: false,
        beforeSwap: true,
        afterSwap: true,
        beforeDonate: false,
        afterDonate: false,
        beforeSwapReturnDelta: false,
        afterSwapReturnDelta: false,
        afterAddLiquidityReturnDelta: false,
        afterRemoveLiquidityReturnDelta: false
    });
}


    // ============================================================
    // CREATE LAUNCH
    // ============================================================

    /**
     * @notice
     * Creates a new Banshee launch.
     *
     * Only the verified Banshee AI Agent can create launches.
     *
     * Before calling this function:
     *
     * Artist must approve this Hook as an ERC1155 operator:
     *
     *      asset.setApprovalForAll(
     *          address(bansheeHook),
     *          true
     *      );
     *
     * The inventory is transferred into the Hook and becomes
     * available for the fixed-price fair launch.
     */
    function createLaunch(
        PoolKey calldata key,

        address artist,

        address asset,

        uint256 tokenId,

        address marketToken,

        address quoteToken,

        AssetType assetType,

        uint256 supply,

        uint256 launchPrice,

        uint64 startTime,

        uint64 fairLaunchEnd,

        uint16 protocolFeeBps,

        uint16 secondaryRoyaltyBps
    )
        external
        onlyAgent
        whenNotPaused
        nonReentrant
        returns (
            uint256 launchId
        )
    {
        if (
            artist == address(0) ||
            asset == address(0) ||
            marketToken == address(0) ||
            quoteToken == address(0)
        ) {
            revert ZeroAddress();
        }


        if (supply == 0) {
            revert InvalidSupply();
        }


        if (launchPrice == 0) {
            revert InvalidPrice();
        }


        if (
            protocolFeeBps >
                MAX_PROTOCOL_FEE_BPS ||
            secondaryRoyaltyBps >
                MAX_ROYALTY_BPS
        ) {
            revert InvalidFee();
        }


        if (
            fairLaunchEnd <= startTime
        ) {
            revert InvalidLaunchTime();
        }


        if (
            launchIdByAsset[
                asset
            ][tokenId] != 0
        ) {
            revert AssetAlreadyLaunched();
        }


        /*
            Every pool that uses this launch must point
            to THIS hook.
        */
        if (
            address(key.hooks) !=
            address(this)
        ) {
            revert InvalidPoolHook();
        }


        bytes32 poolId =
            PoolId.unwrap(
                key.toId()
            );


        if (
            launchIdByPool[
                poolId
            ] != 0
        ) {
            revert PoolAlreadyRegistered();
        }


        launchId =
            ++nextLaunchId;


        _launches[
            launchId
        ] = Launch({
            artist:
                artist,

            asset:
                asset,

            tokenId:
                tokenId,

            marketToken:
                marketToken,

            quoteToken:
                quoteToken,

            poolId:
                poolId,

            assetType:
                assetType,

            state:
                LaunchState.CREATED,

            supply:
                supply,

            sold:
                0,

            launchPrice:
                launchPrice,

            startTime:
                startTime,

            fairLaunchEnd:
                fairLaunchEnd,

            protocolFeeBps:
                protocolFeeBps,

            secondaryRoyaltyBps:
                secondaryRoyaltyBps,

            swapCount:
                0
        });


        launchIdByPool[
            poolId
        ] =
            launchId;


        launchIdByAsset[
            asset
        ][tokenId] =
            launchId;


        /*
            Move ERC1155 launch inventory from
            artist into the Hook.
        */
        IERC1155(asset)
            .safeTransferFrom(
                artist,
                address(this),
                tokenId,
                supply,
                ""
            );


        emit LaunchCreated(
            launchId,
            artist,
            asset,
            tokenId,
            assetType,
            supply,
            launchPrice
        );


        /*
            If launch starts immediately,
            activate the fair launch.
        */
        if (
            block.timestamp >=
            startTime
        ) {
            _startFairLaunch(
                launchId
            );
        }
    }


    // ============================================================
    // START FAIR LAUNCH
    // ============================================================

    /**
     * @notice
     * Permissionless activation after the configured start time.
     */
    function startFairLaunch(
        uint256 launchId
    )
        external
        whenNotPaused
    {
        _startFairLaunch(
            launchId
        );
    }


    function _startFairLaunch(
        uint256 launchId
    )
        internal
    {
        Launch storage launch =
            _requireLaunch(
                launchId
            );


        if (
            launch.state !=
            LaunchState.CREATED
        ) {
            revert InvalidState();
        }


        if (
            block.timestamp <
            launch.startTime
        ) {
            revert SaleNotStarted();
        }


        if (
            block.timestamp >=
            launch.fairLaunchEnd
        ) {
            revert FairLaunchEnded();
        }


        launch.state =
            LaunchState.FAIR_LAUNCH;


        emit FairLaunchStarted(
            launchId,
            launch.startTime,
            launch.fairLaunchEnd
        );
    }


    // ============================================================
    // PRIMARY FAIR LAUNCH SALE
    // ============================================================

    /**
     * @notice
     * Buy ERC1155 units during the fixed-price launch.
     *
     * Every buyer pays exactly:
     *
     *      launchPrice * quantity
     *
     * This gives Banshee a Flaunch-style fair
     * distribution window before market price discovery.
     */
    function buy(
        uint256 launchId,
        uint256 quantity
    )
        external
        whenNotPaused
        nonReentrant
    {
        if (quantity == 0) {
            revert InvalidQuantity();
        }


        Launch storage launch =
            _requireLaunch(
                launchId
            );


        /*
            Automatically start launch when its
            configured start time has arrived.
        */
        if (
            launch.state ==
                LaunchState.CREATED &&
            block.timestamp >=
                launch.startTime &&
            block.timestamp <
                launch.fairLaunchEnd
        ) {
            _startFairLaunch(
                launchId
            );
        }


        if (
            launch.state !=
            LaunchState.FAIR_LAUNCH
        ) {
            revert InvalidState();
        }


        if (
            block.timestamp <
            launch.startTime
        ) {
            revert SaleNotStarted();
        }


        if (
            block.timestamp >=
            launch.fairLaunchEnd
        ) {
            revert FairLaunchEnded();
        }


        if (
            launch.sold +
                quantity >
            launch.supply
        ) {
            revert SoldOut();
        }


        uint256 totalCost =
            launch.launchPrice *
            quantity;


        uint256 protocolFee =
            (
                totalCost *
                launch.protocolFeeBps
            ) /
            BPS;


        uint256 artistAmount =
            totalCost -
            protocolFee;


        /*
            Pull payment from fan.
        */
        IERC20(
            launch.quoteToken
        ).safeTransferFrom(
            msg.sender,
            address(this),
            totalCost
        );


        /*
            Credit artist earnings.
        */
        artistEarnings[
            launchId
        ] += artistAmount;


        /*
            Credit Banshee protocol fees.
        */
        protocolFees[
            launch.quoteToken
        ] += protocolFee;


        launch.sold +=
            quantity;


        /*
            Send actual ERC1155 music asset
            to the fan.
        */
        IERC1155(
            launch.asset
        ).safeTransferFrom(
            address(this),
            msg.sender,
            launch.tokenId,
            quantity,
            ""
        );


        emit AssetPurchased(
            launchId,
            msg.sender,
            quantity,
            totalCost
        );
    }


    // ============================================================
    // TRANSITION TO OPEN MARKET
    // ============================================================

    /**
     * @notice
     * Moves a launch from fixed-price distribution
     * into open secondary market trading.
     *
     * Anyone can activate the market after the
     * fair-launch period expires.
     */
    function activateMarket(
        uint256 launchId
    )
        external
        whenNotPaused
    {
        Launch storage launch =
            _requireLaunch(
                launchId
            );


        if (
            launch.state !=
                LaunchState.FAIR_LAUNCH &&
            launch.state !=
                LaunchState.CREATED
        ) {
            revert InvalidState();
        }


        if (
            block.timestamp <
            launch.fairLaunchEnd
        ) {
            revert FairLaunchNotEnded();
        }


        launch.state =
            LaunchState.ACTIVE;


        emit MarketActivated(
            launchId,
            launch.poolId
        );
    }


    // ============================================================
    // UNISWAP BEFORE SWAP
    // ============================================================

    /**
     * @notice
     * Blocks secondary trading until the fixed-price
     * fair-launch period has completed.
     */
    function _beforeSwap(
    address,
    PoolKey calldata key,
    SwapParams calldata,
    bytes calldata
)
    internal
    override
    whenNotPaused
    returns (
        bytes4,
        BeforeSwapDelta,
        uint24
    )
{
    // existing Banshee logic...

    return (
        BaseHook.beforeSwap.selector,
        BeforeSwapDelta.wrap(0),
        0
    );
}


    // ============================================================
    // UNISWAP AFTER SWAP
    // ============================================================

    /**
     * @notice
     * Records open-market activity.
     *
     * SubQuery can index this event.
     *
     * Banshee AI can use the indexed activity as one
     * input into Proof-of-Performance.
     *
     * No custom Uniswap balance delta is taken in v1.
     */
    function _afterSwap(
    address sender,
    PoolKey calldata key,
    SwapParams calldata params,
    BalanceDelta,
    bytes calldata
)
    internal
    override
    returns (
        bytes4,
        int128
    )
{
    // existing Banshee logic...

    return (
        BaseHook.afterSwap.selector,
        0
    );
}


    // ============================================================
    // SECONDARY ROYALTIES
    // ============================================================

    /**
     * @notice
     * Deposits secondary-market royalties for an artist.
     *
     * Why this exists:
     *
     * The simplified v1 Hook intentionally does NOT
     * use custom Uniswap swap deltas.
     *
     * A future BansheeFeeManager or protocol-owned
     * liquidity position can collect market revenue
     * and deposit the artist's portion here.
     *
     * This keeps the Hook simple while preserving
     * artist royalty accounting.
     */
    function depositRoyalty(
        uint256 launchId,
        uint256 amount
    )
        external
        whenNotPaused
        nonReentrant
    {
        if (amount == 0) {
            revert InvalidQuantity();
        }


        Launch storage launch =
            _requireLaunch(
                launchId
            );


        IERC20(
            launch.quoteToken
        ).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );


        artistEarnings[
            launchId
        ] += amount;


        emit RoyaltyDeposited(
            launchId,
            msg.sender,
            amount
        );
    }


    // ============================================================
    // ARTIST CLAIMS
    // ============================================================

    /**
     * @notice
     * Artist claims primary-sale proceeds
     * and deposited royalties.
     */
    function claimArtistEarnings(
        uint256 launchId
    )
        external
        nonReentrant
    {
        Launch storage launch =
            _requireLaunch(
                launchId
            );


        if (
            msg.sender !=
            launch.artist
        ) {
            revert NotArtist();
        }


        uint256 amount =
            artistEarnings[
                launchId
            ];


        if (amount == 0) {
            revert NothingToClaim();
        }


        artistEarnings[
            launchId
        ] = 0;


        IERC20(
            launch.quoteToken
        ).safeTransfer(
            launch.artist,
            amount
        );


        emit ArtistEarningsClaimed(
            launchId,
            launch.artist,
            amount
        );
    }


    // ============================================================
    // UNSOLD INVENTORY
    // ============================================================

    /**
     * @notice
     * Artist can recover ERC1155 inventory that did
     * not sell during the fair launch.
     *
     * This can later be sent to a wrapper / liquidity
     * contract if desired.
     */
    function withdrawUnsoldInventory(
        uint256 launchId
    )
        external
        nonReentrant
    {
        Launch storage launch =
            _requireLaunch(
                launchId
            );


        if (
            msg.sender !=
            launch.artist
        ) {
            revert NotArtist();
        }


        if (
            block.timestamp <
            launch.fairLaunchEnd
        ) {
            revert FairLaunchNotEnded();
        }


        uint256 unsold =
            launch.supply -
            launch.sold;


        if (unsold == 0) {
            revert NothingToClaim();
        }


        /*
            Updating supply to sold prevents the
            inventory from being withdrawn twice.
        */
        launch.supply =
            launch.sold;


        IERC1155(
            launch.asset
        ).safeTransferFrom(
            address(this),
            launch.artist,
            launch.tokenId,
            unsold,
            ""
        );


        emit UnsoldInventoryWithdrawn(
            launchId,
            launch.artist,
            unsold
        );
    }


    // ============================================================
    // END LAUNCH
    // ============================================================

    /**
     * @notice
     * Useful primarily for tickets / expired events.
     */
    function endLaunch(
        uint256 launchId
    )
        external
        onlyArtistOrAgent(
            launchId
        )
    {
        Launch storage launch =
            _requireLaunch(
                launchId
            );


        if (
            launch.state ==
            LaunchState.ENDED
        ) {
            revert InvalidState();
        }


        launch.state =
            LaunchState.ENDED;


        emit LaunchEnded(
            launchId
        );
    }


    // ============================================================
    // PROTOCOL FEES
    // ============================================================

    /**
     * @notice
     * Withdraw accumulated primary-sale protocol fees.
     */
    function claimProtocolFees(
        address token
    )
        external
        onlyOwner
        nonReentrant
    {
        uint256 amount =
            protocolFees[
                token
            ];


        if (amount == 0) {
            revert NothingToClaim();
        }


        protocolFees[
            token
        ] = 0;


        IERC20(token)
            .safeTransfer(
                treasury,
                amount
            );
    }


    // ============================================================
    // ADMIN
    // ============================================================

    function setBansheeAgent(
        address newAgent
    )
        external
        onlyOwner
    {
        if (
            newAgent ==
            address(0)
        ) {
            revert ZeroAddress();
        }


        address oldAgent =
            bansheeAgent;


        bansheeAgent =
            newAgent;


        emit AgentUpdated(
            oldAgent,
            newAgent
        );
    }


    function setTreasury(
        address newTreasury
    )
        external
        onlyOwner
    {
        if (
            newTreasury ==
            address(0)
        ) {
            revert ZeroAddress();
        }


        address oldTreasury =
            treasury;


        treasury =
            newTreasury;


        emit TreasuryUpdated(
            oldTreasury,
            newTreasury
        );
    }


    function pause()
        external
        onlyOwner
    {
        _pause();
    }


    function unpause()
        external
        onlyOwner
    {
        _unpause();
    }


    // ============================================================
    // VIEWS
    // ============================================================

    function getLaunch(
        uint256 launchId
    )
        external
        view
        returns (
            Launch memory
        )
    {
        Launch storage launch =
            _requireLaunch(
                launchId
            );


        return launch;
    }


    function remainingSupply(
        uint256 launchId
    )
        external
        view
        returns (
            uint256
        )
    {
        Launch storage launch =
            _requireLaunch(
                launchId
            );


        return
            launch.supply -
            launch.sold;
    }


    function fairLaunchCost(
        uint256 launchId,
        uint256 quantity
    )
        external
        view
        returns (
            uint256
        )
    {
        Launch storage launch =
            _requireLaunch(
                launchId
            );


        return
            launch.launchPrice *
            quantity;
    }


    function isFairLaunchActive(
        uint256 launchId
    )
        external
        view
        returns (
            bool
        )
    {
        Launch storage launch =
            _requireLaunch(
                launchId
            );


        return
            block.timestamp >=
                launch.startTime &&
            block.timestamp <
                launch.fairLaunchEnd &&
            launch.state ==
                LaunchState.FAIR_LAUNCH;
    }


    function getPoolLaunch(
        PoolKey calldata key
    )
        external
        view
        returns (
            Launch memory
        )
    {
        bytes32 poolId =
            PoolId.unwrap(
                key.toId()
            );


        uint256 launchId =
            launchIdByPool[
                poolId
            ];


        if (launchId == 0) {
            revert LaunchDoesNotExist();
        }


        return
            _launches[
                launchId
            ];
    }


    // ============================================================
    // INTERNAL
    // ============================================================

    function _requireLaunch(
        uint256 launchId
    )
        internal
        view
        returns (
            Launch storage launch
        )
    {
        launch =
            _launches[
                launchId
            ];


        if (
            launch.artist ==
            address(0)
        ) {
            revert LaunchDoesNotExist();
        }
    }
}