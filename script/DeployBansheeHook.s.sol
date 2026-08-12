// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from
    "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {BansheeHook} from
    "../src/BansheeHook.sol";

/**
 * @title BansheeCreate2Factory
 *
 * @notice
 * Small CREATE2 factory used to deploy BansheeHook
 * to a Uniswap-v4-compatible hook address.
 *
 * Uniswap v4 determines hook permissions from
 * the low-order bits of the hook contract address.
 */
contract BansheeCreate2Factory {

    error DeploymentFailed();

    function deploy(
        bytes memory creationCode,
        bytes32 salt
    )
        external
        returns (address deployed)
    {
        assembly {
            deployed := create2(
                0,
                add(creationCode, 0x20),
                mload(creationCode),
                salt
            )
        }

        if (deployed == address(0)) {
            revert DeploymentFailed();
        }
    }

    function computeAddress(
        bytes32 salt,
        bytes32 creationCodeHash
    )
        external
        view
        returns (address)
    {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(this),
                            salt,
                            creationCodeHash
                        )
                    )
                )
            )
        );
    }
}


/**
 * @title DeployBansheeHook
 *
 * @notice
 * Deploys BansheeHook with the required
 * Uniswap v4 hook permission bits.
 *
 * Enabled callbacks:
 *
 *      beforeSwap
 *      afterSwap
 *
 * Therefore the required low-order hook flags are:
 *
 *      BEFORE_SWAP_FLAG = 1 << 7
 *      AFTER_SWAP_FLAG  = 1 << 6
 *
 * Combined:
 *
 *      0x00C0
 *
 * No .env is required.
 *
 * You only need to configure the addresses below
 * before running the deployment.
 */
contract DeployBansheeHook is Script {

    // ============================================================
    // UNISWAP HOOK FLAGS
    // ============================================================

    uint160 internal constant BEFORE_SWAP_FLAG =
        1 << 7;

    uint160 internal constant AFTER_SWAP_FLAG =
        1 << 6;

    uint160 internal constant REQUIRED_FLAGS =
        BEFORE_SWAP_FLAG |
        AFTER_SWAP_FLAG;

    /**
     * Uniswap v4 currently uses the lowest
     * 14 bits for hook permissions.
     */
    uint160 internal constant ALL_HOOK_MASK =
        (1 << 14) - 1;


    // ============================================================
    // DEPLOYMENT CONFIGURATION
    // ============================================================

    /**
     * IMPORTANT:
     *
     * Replace these values before deployment.
     *
     * POOL_MANAGER:
     *     Uniswap v4 PoolManager on your target chain.
     *
     * OWNER:
     *     Protocol administrator.
     *
     * BANSHEE_AGENT:
     *     Wallet controlled by the Banshee AI backend.
     *
     * TREASURY:
     *     Banshee protocol treasury.
     */

    address internal constant POOL_MANAGER =
        address(0x817F1C7DA96Fa797DEAcc4F0aee9B73aB13469F4);

    address internal constant OWNER =
        address(0x817F1C7DA96Fa797DEAcc4F0aee9B73aB13469F4);

    address internal constant BANSHEE_AGENT =
        address(0x817F1C7DA96Fa797DEAcc4F0aee9B73aB13469F4);

    address internal constant TREASURY =
        address(0x817F1C7DA96Fa797DEAcc4F0aee9B73aB13469F4);


    // ============================================================
    // ERRORS
    // ============================================================

    error InvalidConfiguration();

    error InvalidHookAddress();


    // ============================================================
    // RUN
    // ============================================================

    function run()
        external
        returns (BansheeHook hook)
    {
        // --------------------------------------------------------
        // Validate configuration
        // --------------------------------------------------------

        if (
            POOL_MANAGER == address(0) ||
            OWNER == address(0) ||
            BANSHEE_AGENT == address(0) ||
            TREASURY == address(0)
        ) {
            revert InvalidConfiguration();
        }


        // --------------------------------------------------------
        // Deploy CREATE2 factory
        // --------------------------------------------------------

        vm.startBroadcast();

        BansheeCreate2Factory factory =
            new BansheeCreate2Factory();

        vm.stopBroadcast();


        console2.log(
            "CREATE2 Factory:"
        );

        console2.log(
            address(factory)
        );


        // --------------------------------------------------------
        // Build BansheeHook creation bytecode
        // --------------------------------------------------------

        bytes memory creationCode =
            abi.encodePacked(
                type(BansheeHook).creationCode,

                abi.encode(
                    IPoolManager(
                        POOL_MANAGER
                    ),

                    OWNER,

                    BANSHEE_AGENT,

                    TREASURY
                )
            );


        bytes32 creationCodeHash =
            keccak256(
                creationCode
            );


        // --------------------------------------------------------
        // Mine hook address
        // --------------------------------------------------------

        (
            bytes32 salt,
            address predictedHook
        ) =
            _findSalt(
                address(factory),
                creationCodeHash
            );


        console2.log(
            "Salt:"
        );

        console2.logBytes32(
            salt
        );


        console2.log(
            "Predicted Hook:"
        );

        console2.log(
            predictedHook
        );


        // --------------------------------------------------------
        // Verify permission bits
        // --------------------------------------------------------

        if (
            (
                uint160(
                    predictedHook
                ) &
                ALL_HOOK_MASK
            )
            !=
            REQUIRED_FLAGS
        ) {
            revert InvalidHookAddress();
        }


        // --------------------------------------------------------
        // Deploy hook
        // --------------------------------------------------------

        vm.startBroadcast();

        address deployed =
            factory.deploy(
                creationCode,
                salt
            );

        vm.stopBroadcast();


        if (
            deployed !=
            predictedHook
        ) {
            revert InvalidHookAddress();
        }


        hook =
            BansheeHook(
                payable(
                    deployed
                )
            );


        // --------------------------------------------------------
        // Deployment summary
        // --------------------------------------------------------

        console2.log("");
        console2.log(
            "======================================"
        );

        console2.log(
            "BANSHEE HOOK DEPLOYED"
        );

        console2.log(
            "======================================"
        );

        console2.log(
            "Hook:"
        );

        console2.log(
            address(hook)
        );


        console2.log(
            "PoolManager:"
        );

        console2.log(
            POOL_MANAGER
        );


        console2.log(
            "Owner:"
        );

        console2.log(
            OWNER
        );


        console2.log(
            "Banshee AI Agent:"
        );

        console2.log(
            BANSHEE_AGENT
        );


        console2.log(
            "Treasury:"
        );

        console2.log(
            TREASURY
        );


        console2.log(
            "Hook Flags:"
        );

        console2.log(
            uint256(
                REQUIRED_FLAGS
            )
        );


        console2.log(
            "======================================"
        );
    }


    // ============================================================
    // CREATE2 SALT MINER
    // ============================================================

    /**
     * @notice
     * Searches for a CREATE2 salt whose resulting
     * address has the required Uniswap v4 hook flags.
     *
     * This computation takes place locally while
     * forge script is running.
     */
    function _findSalt(
        address deployer,
        bytes32 creationCodeHash
    )
        internal
        pure
        returns (
            bytes32 salt,
            address predicted
        )
    {
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
                                    bytes1(0xff),

                                    deployer,

                                    salt,

                                    creationCodeHash
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
                return (
                    salt,
                    predicted
                );
            }
        }


        revert InvalidHookAddress();
    }
}