// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import {Pool} from './libraries/Pool.sol';
import {Tick} from './libraries/Tick.sol';
import {SafeCast} from './libraries/SafeCast.sol';

import {IERC20Minimal} from './interfaces/external/IERC20Minimal.sol';
import {NoDelegateCall} from './NoDelegateCall.sol';
import {IPoolManager} from './interfaces/IPoolManager.sol';
import {ILockCallback} from './interfaces/callback/ILockCallback.sol';
import {TransientStorageProxy, TransientStorage} from './libraries/TransientStorage.sol';

/// @notice Holds the state for all pools
contract PoolManager is IPoolManager, NoDelegateCall {
    using SafeCast for *;
    using Pool for *;
    using TransientStorage for TransientStorageProxy;

    mapping(bytes32 => Pool.State) public pools;

    TransientStorageProxy public immutable transientStorage;

    constructor() {
        transientStorage = TransientStorage.init();
    }

    /// @dev For mocking in unit tests
    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp);
    }

    function _getPool(IPoolManager.PoolKey memory key) private view returns (Pool.State storage) {
        return pools[keccak256(abi.encode(key))];
    }

    /// @notice Initialize the state for a given pool ID
    function initialize(IPoolManager.PoolKey memory key, uint160 sqrtPriceX96) external override returns (int24 tick) {
        tick = _getPool(key).initialize(_blockTimestamp(), sqrtPriceX96);
    }

    /// @notice Increase the maximum number of stored observations for the pool's oracle
    function increaseObservationCardinalityNext(IPoolManager.PoolKey memory key, uint16 observationCardinalityNext)
        external
        override
        returns (uint16 observationCardinalityNextOld, uint16 observationCardinalityNextNew)
    {
        (observationCardinalityNextOld, observationCardinalityNextNew) = _getPool(key)
            .increaseObservationCardinalityNext(observationCardinalityNext);
    }

    /// @inheritdoc IPoolManager
    mapping(IERC20Minimal => uint256) public override reservesOf;

    uint256 public constant LOCKED_BY_SLOT = uint256(keccak256('lockedBy'));
    uint256 public constant TOKENS_TOUCHED_SLOT = uint256(keccak256('tokensTouched'));
    uint256 public constant TOKEN_DELTA_SLOT = uint256(keccak256('tokenDelta'));

    function lockedBy() public returns (address) {
        return address(uint160(transientStorage.load(LOCKED_BY_SLOT)));
    }

    function setLockedBy(address addr) internal {
        transientStorage.store(LOCKED_BY_SLOT, uint256(uint160(addr)));
    }

    function tokensTouchedLength() public returns (uint256) {
        return transientStorage.load(TOKENS_TOUCHED_SLOT);
    }

    function tokensTouched(uint256 ix) public returns (IERC20Minimal) {
        unchecked {
            return IERC20Minimal(address(uint160(transientStorage.load(TOKENS_TOUCHED_SLOT + ix + 1))));
        }
    }

    function pushTokenTouched(IERC20Minimal token) internal {
        uint256 len = tokensTouchedLength();
        if (len >= type(uint8).max) revert MaxTokensTouched(token);

        unchecked {
            transientStorage.store(TOKENS_TOUCHED_SLOT, len + 1);
            transientStorage.store(TOKENS_TOUCHED_SLOT + len + 1, uint256(uint160(address(token))));
        }
    }

    struct PositionAndDelta {
        uint8 slot;
        int248 delta;
    }

    function tokenDelta(IERC20Minimal token) public returns (PositionAndDelta memory pd) {
        uint256 storageSlot = uint256(keccak256(abi.encodePacked(TOKEN_DELTA_SLOT, token)));
        uint256 value = transientStorage.load(storageSlot);
        pd.slot = uint8(value >> 248);
        pd.delta = int248(uint248(value & ~uint256(0xff << 248)));
    }

    function setTokenDelta(IERC20Minimal token, PositionAndDelta memory pd) internal {
        uint256 storageSlot = uint256(keccak256(abi.encodePacked(TOKEN_DELTA_SLOT, token)));
        uint256 value = (uint256(pd.slot) << 248) | uint256(uint248(pd.delta));
        transientStorage.store(storageSlot, value);
    }

    /// @dev Limited to 256 since the slot in the mapping is a uint8. It is unexpected for any set of actions to involve
    ///     more than 256 tokens.
    uint256 public constant MAX_TOKENS_TOUCHED = type(uint8).max;

    function lock(bytes calldata data) external override returns (bytes memory result) {
        if (lockedBy() != address(0)) revert AlreadyLocked(lockedBy());
        setLockedBy(msg.sender);

        // the caller does everything in this callback, including paying what they owe via calls to settle
        result = ILockCallback(msg.sender).lockAcquired(data);

        unchecked {
            uint256 len = tokensTouchedLength();
            for (uint256 i; i < len; i++) {
                IERC20Minimal token = tokensTouched(i);
                PositionAndDelta memory pd = tokenDelta(token);
                if (pd.delta != 0) revert TokenNotSettled(token, pd.delta);
                // TODO: this should not be necessary, transient storage should automatically clear
                pd.slot = 0;
                setTokenDelta(token, pd);
            }
        }

        // TODO: this should not be necessary, transient storage should automatically clear
        transientStorage.store(TOKENS_TOUCHED_SLOT, 0);
        setLockedBy(address(0));
    }

    /// @dev Adds a token to a unique list of tokens that have been touched
    function _addTokenToSet(IERC20Minimal token) internal {
        uint256 len = tokensTouchedLength();
        if (len == 0) {
            pushTokenTouched(token);
            return;
        }

        PositionAndDelta memory pd = tokenDelta(token);

        // we only need to add it if the slot is set to 0 and the token in slot 0 is not this token (i.e. slot 0 is not correct)
        if (pd.slot == 0 && tokensTouched(0) != token) {
            pushTokenTouched(token);
        }
    }

    function _accountDelta(IERC20Minimal token, int256 delta) internal {
        if (delta == 0) return;
        _addTokenToSet(token);
        PositionAndDelta memory pd = tokenDelta(token);
        pd.delta += int248(delta);
        setTokenDelta(token, pd);
    }

    /// @dev Accumulates a balance change to a map of token to balance changes
    function _accountPoolBalanceDelta(PoolKey memory key, Pool.BalanceDelta memory delta) internal {
        _accountDelta(key.token0, delta.amount0);
        _accountDelta(key.token1, delta.amount1);
    }

    modifier onlyByLocker() {
        address lb = lockedBy();
        if (msg.sender != lb) revert LockedBy(lb);
        _;
    }

    /// @dev Modify the position
    function modifyPosition(IPoolManager.PoolKey memory key, IPoolManager.ModifyPositionParams memory params)
        external
        override
        noDelegateCall
        onlyByLocker
        returns (Pool.BalanceDelta memory delta)
    {
        delta = _getPool(key).modifyPosition(
            Pool.ModifyPositionParams({
                owner: msg.sender,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: params.liquidityDelta.toInt128(),
                time: _blockTimestamp(),
                maxLiquidityPerTick: Tick.tickSpacingToMaxLiquidityPerTick(key.tickSpacing),
                tickSpacing: key.tickSpacing
            })
        );

        _accountPoolBalanceDelta(key, delta);
    }

    function swap(IPoolManager.PoolKey memory key, IPoolManager.SwapParams memory params)
        external
        override
        noDelegateCall
        onlyByLocker
        returns (Pool.BalanceDelta memory delta)
    {
        delta = _getPool(key).swap(
            Pool.SwapParams({
                time: _blockTimestamp(),
                fee: key.fee,
                tickSpacing: key.tickSpacing,
                zeroForOne: params.zeroForOne,
                amountSpecified: params.amountSpecified,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
            })
        );

        _accountPoolBalanceDelta(key, delta);
    }

    /// @notice Called by the user to net out some value owed to the user
    /// @dev Can also be used as a mechanism for _free_ flash loans
    function take(
        IERC20Minimal token,
        address to,
        uint256 amount
    ) external override noDelegateCall onlyByLocker {
        _accountDelta(token, amount.toInt256());
        reservesOf[token] -= amount;
        token.transfer(to, amount);
    }

    /// @notice Called by the user to pay what is owed
    function settle(IERC20Minimal token) external override noDelegateCall onlyByLocker returns (uint256 paid) {
        uint256 reservesBefore = reservesOf[token];
        reservesOf[token] = token.balanceOf(address(this));
        paid = reservesOf[token] - reservesBefore;
        // subtraction must be safe
        _accountDelta(token, -(paid.toInt256()));
    }

    /// @notice Update the protocol fee for a given pool
    function setFeeProtocol(IPoolManager.PoolKey calldata key, uint8 feeProtocol)
        external
        override
        returns (uint8 feeProtocolOld)
    {
        return _getPool(key).setFeeProtocol(feeProtocol);
    }

    /// @notice Observe a past state of a pool
    function observe(IPoolManager.PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        override
        noDelegateCall
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        return _getPool(key).observe(_blockTimestamp(), secondsAgos);
    }

    /// @notice Get the snapshot of the cumulative values of a tick range
    function snapshotCumulativesInside(
        IPoolManager.PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper
    ) external view override noDelegateCall returns (Pool.Snapshot memory) {
        return _getPool(key).snapshotCumulativesInside(tickLower, tickUpper, _blockTimestamp());
    }
}