// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "../types/PoolKey.sol";
import {IHooks} from "../interfaces/IHooks.sol";
import {SafeCast} from "../libraries/SafeCast.sol";
import {SwapFeeLibrary} from "./SwapFeeLibrary.sol";
import {BalanceDelta} from "../types/BalanceDelta.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";

/// @notice V4 decides whether to invoke specific hooks by inspecting the leading bits of the address that
/// the hooks contract is deployed to.
/// For example, a hooks contract deployed to address: 0x9000000000000000000000000000000000000000
/// has leading bits '1001' which would cause the 'before initialize' and 'after add liquidity' hooks to be used.
library Hooks {
    using SwapFeeLibrary for uint24;
    using Hooks for IHooks;
    using SafeCast for int256;

    uint256 internal constant BEFORE_INITIALIZE_FLAG = 1 << 159;
    uint256 internal constant AFTER_INITIALIZE_FLAG = 1 << 158;

    uint256 internal constant BEFORE_ADD_LIQ_FLAG = 1 << 157;
    uint256 internal constant AFTER_ADD_LIQ_FLAG = 1 << 156;

    uint256 internal constant BEFORE_REMOVE_LIQ_FLAG = 1 << 155;
    uint256 internal constant AFTER_REMOVE_LIQ_FLAG = 1 << 154;

    uint256 internal constant BEFORE_SWAP_FLAG = 1 << 153;
    uint256 internal constant AFTER_SWAP_FLAG = 1 << 152;

    uint256 internal constant BEFORE_DONATE_FLAG = 1 << 151;
    uint256 internal constant AFTER_DONATE_FLAG = 1 << 150;

    uint256 internal constant BEFORE_SWAP_RETURNS_DELTA_FLAG = 1 << 149;
    uint256 internal constant AFTER_SWAP_RETURNS_DELTA_FLAG = 1 << 148;
    uint256 internal constant AFTER_ADD_LIQ_RETURNS_DELTA_FLAG = 1 << 147;
    uint256 internal constant AFTER_REMOVE_LIQ_RETURNS_DELTA_FLAG = 1 << 146;

    struct Permissions {
        bool beforeInitialize;
        bool afterInitialize;
        bool beforeAddLiquidity;
        bool afterAddLiquidity;
        bool beforeRemoveLiquidity;
        bool afterRemoveLiquidity;
        bool beforeSwap;
        bool afterSwap;
        bool beforeDonate;
        bool afterDonate;
        bool beforeSwapReturnDelta;
        bool afterSwapReturnDelta;
        bool afterAddLiqReturnDelta;
        bool afterRemoveLiqReturnDelta;
    }

    /// @notice Thrown if the address will not lead to the specified hook calls being called
    /// @param hooks The address of the hooks contract
    error HookAddressNotValid(address hooks);

    /// @notice Hook did not return its selector
    error InvalidHookResponse();

    /// @notice thrown when a hook call fails
    error FailedHookCall();

    /// @notice Utility function intended to be used in hook constructors to ensure
    /// the deployed hooks address causes the intended hooks to be called
    /// @param permissions The hooks that are intended to be called
    /// @dev permissions param is memory as the function will be called from constructors
    function validateHookPermissions(IHooks self, Permissions memory permissions) internal pure {
        if (
            permissions.beforeInitialize != self.hasPermission(BEFORE_INITIALIZE_FLAG)
                || permissions.afterInitialize != self.hasPermission(AFTER_INITIALIZE_FLAG)
                || permissions.beforeAddLiquidity != self.hasPermission(BEFORE_ADD_LIQ_FLAG)
                || permissions.afterAddLiquidity != self.hasPermission(AFTER_ADD_LIQ_FLAG)
                || permissions.beforeRemoveLiquidity != self.hasPermission(BEFORE_REMOVE_LIQ_FLAG)
                || permissions.afterRemoveLiquidity != self.hasPermission(AFTER_REMOVE_LIQ_FLAG)
                || permissions.beforeSwap != self.hasPermission(BEFORE_SWAP_FLAG)
                || permissions.afterSwap != self.hasPermission(AFTER_SWAP_FLAG)
                || permissions.beforeDonate != self.hasPermission(BEFORE_DONATE_FLAG)
                || permissions.afterDonate != self.hasPermission(AFTER_DONATE_FLAG)
                || permissions.beforeSwapReturnDelta != self.hasPermission(BEFORE_SWAP_RETURNS_DELTA_FLAG)
                || permissions.afterSwapReturnDelta != self.hasPermission(AFTER_SWAP_RETURNS_DELTA_FLAG)
                || permissions.afterAddLiqReturnDelta != self.hasPermission(AFTER_ADD_LIQ_RETURNS_DELTA_FLAG)
                || permissions.afterRemoveLiqReturnDelta != self.hasPermission(AFTER_REMOVE_LIQ_RETURNS_DELTA_FLAG)
        ) {
            revert HookAddressNotValid(address(self));
        }
    }

    /// @notice Ensures that the hook address includes at least one hook flag or dynamic fees, or is the 0 address
    /// @param hook The hook to verify
    /// @return bool True if the hook address is valid
    function isValidHookAddress(IHooks hook, uint24 fee) internal pure returns (bool) {
        // The hook can only have a flag to return a hook delta if it has the corresponding hook flag
        if (
            (!hook.hasPermission(BEFORE_SWAP_FLAG) && hook.hasPermission(BEFORE_SWAP_RETURNS_DELTA_FLAG))
                || (!hook.hasPermission(AFTER_SWAP_FLAG) && hook.hasPermission(AFTER_SWAP_RETURNS_DELTA_FLAG))
                || (!hook.hasPermission(AFTER_ADD_LIQ_FLAG) && hook.hasPermission(AFTER_ADD_LIQ_RETURNS_DELTA_FLAG))
                || (!hook.hasPermission(AFTER_REMOVE_LIQ_FLAG) && hook.hasPermission(AFTER_REMOVE_LIQ_RETURNS_DELTA_FLAG))
        ) return false;
        // If there is no hook contract set, then fee cannot be dynamic
        // If a hook contract is set, it must have at least 1 flag set, or have a dynamic fee
        return address(hook) == address(0)
            ? !fee.isDynamicFee()
            : (uint160(address(hook)) >= AFTER_REMOVE_LIQ_RETURNS_DELTA_FLAG || fee.isDynamicFee());
    }

    /// @notice performs a hook call using the given calldata on the given hook that doesnt return a delta
    /// @return result The complete data returned by the hook
    function callHook(IHooks self, bytes memory data) internal returns (bytes memory result) {
        bool success;
        (success, result) = address(self).call(data);
        if (!success) _revert(result);

        bytes4 expectedSelector;
        bytes4 selector;
        assembly {
            expectedSelector := mload(add(data, 0x20))
            selector := mload(add(result, 0x20))
        }

        if (selector != expectedSelector) revert InvalidHookResponse();
    }

    /// @notice performs a hook call using the given calldata on the given hook
    /// @return delta The delta returned by the hook
    function callHookWithReturnDelta(IHooks self, bytes memory data, bool parseReturn)
        internal
        returns (int256 delta)
    {
        bytes memory result = callHook(self, data);

        if (!parseReturn) return 0;
        (, delta) = abi.decode(result, (bytes4, int256));
    }

    /// @notice calls beforeInitialize hook if permissioned and validates return value
    function beforeInitialize(IHooks self, PoolKey memory key, uint160 sqrtPriceX96, bytes calldata hookData)
        internal
    {
        if (self.hasPermission(BEFORE_INITIALIZE_FLAG)) {
            self.callHook(
                abi.encodeWithSelector(IHooks.beforeInitialize.selector, msg.sender, key, sqrtPriceX96, hookData)
            );
        }
    }

    /// @notice calls afterInitialize hook if permissioned and validates return value
    function afterInitialize(IHooks self, PoolKey memory key, uint160 sqrtPriceX96, int24 tick, bytes calldata hookData)
        internal
    {
        if (self.hasPermission(AFTER_INITIALIZE_FLAG)) {
            self.callHook(
                abi.encodeWithSelector(IHooks.afterInitialize.selector, msg.sender, key, sqrtPriceX96, tick, hookData)
            );
        }
    }

    /// @notice calls beforeModifyLiquidity hook if permissioned and validates return value
    function beforeModifyLiquidity(
        IHooks self,
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        bytes calldata hookData
    ) internal {
        if (params.liquidityDelta > 0 && key.hooks.hasPermission(BEFORE_ADD_LIQ_FLAG)) {
            self.callHook(abi.encodeWithSelector(IHooks.beforeAddLiquidity.selector, msg.sender, key, params, hookData));
        } else if (params.liquidityDelta <= 0 && key.hooks.hasPermission(BEFORE_REMOVE_LIQ_FLAG)) {
            self.callHook(
                abi.encodeWithSelector(IHooks.beforeRemoveLiquidity.selector, msg.sender, key, params, hookData)
            );
        }
    }

    /// @notice calls afterModifyLiquidity hook if permissioned and validates return value
    function afterModifyLiquidity(
        IHooks self,
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal returns (BalanceDelta hookDelta) {
        if (params.liquidityDelta > 0) {
            if (key.hooks.hasPermission(AFTER_ADD_LIQ_FLAG)) {
                hookDelta = BalanceDelta.wrap(
                    self.callHookWithReturnDelta(
                        abi.encodeWithSelector(
                            IHooks.afterAddLiquidity.selector, msg.sender, key, params, delta, hookData
                        ),
                        key.hooks.hasPermission(AFTER_ADD_LIQ_RETURNS_DELTA_FLAG)
                    )
                );
            }
        } else {
            if (key.hooks.hasPermission(AFTER_REMOVE_LIQ_FLAG)) {
                hookDelta = BalanceDelta.wrap(
                    self.callHookWithReturnDelta(
                        abi.encodeWithSelector(
                            IHooks.afterRemoveLiquidity.selector, msg.sender, key, params, delta, hookData
                        ),
                        key.hooks.hasPermission(AFTER_REMOVE_LIQ_RETURNS_DELTA_FLAG)
                    )
                );
            }
        }
    }

    /// @notice calls beforeSwap hook if permissioned and validates return value
    function beforeSwap(IHooks self, PoolKey memory key, IPoolManager.SwapParams memory params, bytes calldata hookData)
        internal
        returns (int128 hookDeltaInSpecified)
    {
        if (key.hooks.hasPermission(BEFORE_SWAP_FLAG)) {
            hookDeltaInSpecified = self.callHookWithReturnDelta(
                abi.encodeWithSelector(IHooks.beforeSwap.selector, msg.sender, key, params, hookData),
                key.hooks.hasPermission(BEFORE_SWAP_RETURNS_DELTA_FLAG)
            ).toInt128();
        }
    }

    /// @notice calls afterSwap hook if permissioned and validates return value
    function afterSwap(
        IHooks self,
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal returns (int128 hookDeltaInUnspecified) {
        if (key.hooks.hasPermission(AFTER_SWAP_FLAG)) {
            hookDeltaInUnspecified = self.callHookWithReturnDelta(
                abi.encodeWithSelector(IHooks.afterSwap.selector, msg.sender, key, params, delta, hookData),
                key.hooks.hasPermission(AFTER_SWAP_RETURNS_DELTA_FLAG)
            ).toInt128();
        }
    }

    /// @notice calls beforeDonate hook if permissioned and validates return value
    function beforeDonate(IHooks self, PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        internal
    {
        if (key.hooks.hasPermission(BEFORE_DONATE_FLAG)) {
            self.callHook(
                abi.encodeWithSelector(IHooks.beforeDonate.selector, msg.sender, key, amount0, amount1, hookData)
            );
        }
    }

    /// @notice calls afterDonate hook if permissioned and validates return value
    function afterDonate(IHooks self, PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        internal
    {
        if (key.hooks.hasPermission(AFTER_DONATE_FLAG)) {
            self.callHook(
                abi.encodeWithSelector(IHooks.afterDonate.selector, msg.sender, key, amount0, amount1, hookData)
            );
        }
    }

    function hasPermission(IHooks self, uint256 flag) internal pure returns (bool) {
        return uint256(uint160(address(self))) & flag != 0;
    }

    /// @notice bubble up revert if present. Else throw FailedHookCall
    function _revert(bytes memory result) private pure {
        if (result.length == 0) revert FailedHookCall();
        assembly {
            revert(add(0x20, result), mload(result))
        }
    }
}
