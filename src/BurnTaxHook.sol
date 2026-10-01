// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Burns one percent of the gross BTAX leg of swaps, rounded down to token minor units.
/// @dev Implements only the enabled IHooks callbacks. Other selectors revert.
contract BurnTaxHook {
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable poolManager;
    address public immutable launchedToken;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant TAX_BPS = 100;

    error ZeroAddress();
    error OnlyPoolManager();
    error WrongHook();
    error PartialFillOnSpecifiedToken();
    error SpecifiedAmountTooLarge();

    /// @param isBuy True when the trader receives BTAX; independent of currency ordering.
    /// @param amount BTAX minor units sent to DEAD (including zero for a rounded-down tax).
    event Burned(PoolId indexed poolId, bool indexed isBuy, uint256 amount);

    constructor(IPoolManager manager_, address token_) {
        if (address(manager_) == address(0) || token_ == address(0)) revert ZeroAddress();
        poolManager = manager_;
        launchedToken = token_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (address(key.hooks) != address(this)) revert WrongHook();
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (address(key.hooks) != address(this)) revert WrongHook();
        if (!_containsToken(key) || !_tokenIsSpecified(key, params)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }

        // Positive specified delta reserves input on sells, or grosses up output on buys.
        // Never consume the whole input or change exact-input into exact-output.
        uint256 fee = _specifiedFee(params.amountSpecified);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        if (address(key.hooks) != address(this)) revert WrongHook();
        if (!_containsToken(key)) return (IHooks.afterSwap.selector, 0);

        bool tokenIs0 = Currency.unwrap(key.currency0) == launchedToken;
        bool isBuy = params.zeroForOne != tokenIs0;
        int256 tokenDelta = tokenIs0 ? int256(delta.amount0()) : int256(delta.amount1());
        bool specified = _tokenIsSpecified(key, params);
        uint256 fee;
        if (specified) {
            fee = _specifiedFee(params.amountSpecified);
            // afterSwap cannot refund a specified-currency delta. Reject partial fills atomically
            // instead of charging tax on unexecuted volume. No funds move before this check.
            if (tokenDelta != params.amountSpecified + fee.toInt256()) {
                revert PartialFillOnSpecifiedToken();
            }
        } else {
            // Buys split gross output 99:1. Sells add tax to the AMM input; gross/100 == fee.
            // The authenticated manager gives nonnegative output and nonpositive input deltas;
            // widening int128 to int256 also makes negating the minimum int128 safe.
            // forge-lint: disable-next-line(unsafe-typecast)
            fee = isBuy ? uint256(tokenDelta) / 100 : uint256(-tokenDelta) / 99;
        }

        // take debits the hook; the positive return delta credits it by exactly the same amount.
        // Only BTAX is transferred. There is no native-ETH fee or retained hook balance.
        emit Burned(key.toId(), isBuy, fee);
        if (fee != 0) poolManager.take(Currency.wrap(launchedToken), DEAD, fee);
        return (IHooks.afterSwap.selector, specified ? int128(0) : fee.toInt128());
    }

    function _containsToken(PoolKey calldata key) private view returns (bool) {
        return
            Currency.unwrap(key.currency0) == launchedToken || Currency.unwrap(key.currency1) == launchedToken;
    }

    function _tokenIsSpecified(PoolKey calldata key, SwapParams calldata params) private view returns (bool) {
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        return specifiedIs0 == (Currency.unwrap(key.currency0) == launchedToken);
    }

    function _specifiedFee(int256 amount) private pure returns (uint256) {
        // Bound before negation, addition and narrowing. BTAX supply is much smaller than this.
        int256 limit = int256(type(int128).max);
        if (amount < -limit || amount > limit) revert SpecifiedAmountTooLarge();
        // Negation is positive and safe after the bound above.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (amount < 0) return uint256(-amount) / 100;
        // The negative branch has returned, so this amount is nonnegative.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 fee = uint256(amount) / 99;
        if (amount + fee.toInt256() > limit) revert SpecifiedAmountTooLarge();
        return fee;
    }
}
