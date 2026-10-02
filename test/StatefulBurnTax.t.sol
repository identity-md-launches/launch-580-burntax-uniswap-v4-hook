// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

import {HookFixture} from "./helpers/HookFixture.sol";
import {BurnAssertions} from "./helpers/BurnAssertions.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {OpenSyncRouter} from "./Settlement.t.sol";
import {BurnTaxHook} from "src/BurnTaxHook.sol";
import {BurnTaxToken} from "src/BurnTaxToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

contract BurnTaxSequenceHandler is BurnAssertions {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant INITIAL_BALANCE = 1e24;
    PoolRouter public immutable router;
    OpenSyncRouter public immutable openRouter;
    BurnTaxToken public immutable token;
    MockERC20 public immutable quote;
    IPoolManager public immutable manager;
    bool internal immutable tokenIs0;
    PoolKey internal key;
    address[3] public actors;
    int256[3] public expectedToken;
    int256[3] public expectedQuote;
    uint256[3] public positionLiquidity;
    uint256 public expectedBurn;
    uint256 public donatedToDead;
    uint256 public donatedToHook;
    uint256 public trades;
    uint256 public failedTrades;
    uint256 public liquidityCalls;
    uint256 public transfers;
    uint256 public rejectedMintCalls;
    uint256 public deferredTrades;
    uint256 public rejectedDeferredTrades;
    uint256 public finalizations;

    constructor(PoolRouter router_, BurnTaxToken token_, MockERC20 quote_, PoolKey memory key_) {
        router = router_;
        token = token_;
        quote = quote_;
        manager = router_.manager();
        openRouter = new OpenSyncRouter(manager);
        key = key_;
        tokenIs0 = Currency.unwrap(key_.currency0) == address(token_);
        for (uint256 i; i < 3; ++i) {
            actors[i] = address(uint160(0xA1100 + i));
            expectedToken[i] = int256(INITIAL_BALANCE);
            expectedQuote[i] = int256(INITIAL_BALANCE);
            vm.startPrank(actors[i]);
            token_.approve(address(router_), type(uint256).max);
            token_.approve(address(openRouter), type(uint256).max);
            quote_.approve(address(router_), type(uint256).max);
            vm.stopPrank();
        }
    }

    function trade(uint256 actorSeed, uint256 amountSeed, bool buy, bool exactInput, bool prefund) external {
        _trade(actorSeed % 3, bound(amountSeed, 1, 1e20), buy, exactInput, prefund);
    }

    function roundTrip(uint256 actorSeed, uint256 amountSeed) external {
        uint256 i = actorSeed % 3;
        uint256 beforeToken = token.balanceOf(actors[i]);
        uint256 beforeQuote = quote.balanceOf(actors[i]);
        _trade(i, bound(amountSeed, 1000, 1e20), true, true, false);
        uint256 acquired = token.balanceOf(actors[i]) - beforeToken;
        assertGt(acquired, 0, "round trip must execute");
        _trade(i, acquired, false, true, false);
        assertEq(token.balanceOf(actors[i]), beforeToken);
        assertLt(quote.balanceOf(actors[i]), beforeQuote, "two trades cannot create quote profit");
    }

    function transferOrDonate(uint256 actorSeed, uint256 destinationSeed, uint256 amountSeed) external {
        uint256 i = actorSeed % 3;
        uint256 destination = destinationSeed % 5;
        uint256 amount = bound(amountSeed, 0, 1e20);
        address recipient =
            destination < 3 ? actors[destination] : (destination == 3 ? DEAD : address(key.hooks));
        uint256 beforeBalance = token.balanceOf(recipient);
        vm.prank(actors[i]);
        token.transfer(recipient, amount);
        expectedToken[i] -= int256(amount);
        if (destination < 3) expectedToken[destination] += int256(amount);
        else if (destination == 3) donatedToDead += amount;
        else donatedToHook += amount;
        assertEq(
            token.balanceOf(recipient),
            beforeBalance + (recipient == actors[i] ? 0 : amount),
            "ordinary transfer is untaxed"
        );
        ++transfers;
    }

    function changeLiquidity(uint256 actorSeed, uint256 amountSeed, bool remove) external {
        uint256 i = actorSeed % 3;
        uint256 amount;
        if (remove && positionLiquidity[i] != 0) {
            // Include full exits, followed by fresh adds in later calls.
            amount = bound(amountSeed, 1, positionLiquidity[i]);
            positionLiquidity[i] -= amount;
        } else {
            remove = false;
            amount = bound(amountSeed, 1, 1e21);
            positionLiquidity[i] += amount;
        }
        uint256 beforeBurn = token.balanceOf(DEAD);
        vm.recordLogs();
        vm.prank(actors[i]);
        BalanceDelta delta = router.modify(
            key, ModifyLiquidityParams(-600, 600, remove ? -int256(amount) : int256(amount), bytes32(i + 1))
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 j; j < logs.length; ++j) {
            assertNotEq(logs[j].emitter, address(key.hooks));
        }
        _account(i, delta);
        assertEq(token.balanceOf(DEAD), beforeBurn, "liquidity is untaxed");
        ++liquidityCalls;
    }

    function rejectedTrade(uint256 actorSeed, uint256 amountSeed, bool buy) external {
        uint256 i = actorSeed % 3;
        uint256 amount = bound(amountSeed, 100, 1e20);
        address input = buy ? address(quote) : address(token);
        vm.prank(actors[i]);
        BurnTaxToken(input).approve(address(router), amount - 1);
        bytes32 beforeState = _stateDigest(i);
        vm.prank(actors[i]);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(router), amount - 1, amount
            )
        );
        router.swap(key, _params(buy, true, amount), 0, type(uint128).max, 0);
        assertEq(_stateDigest(i), beforeState, "failed sequence step changed accounting");
        vm.prank(actors[i]);
        BurnTaxToken(input).approve(address(router), type(uint256).max);
        ++failedTrades;
    }

    function forbiddenMint(uint256 actorSeed, uint256 amount) external {
        vm.prank(actors[actorSeed % 3]);
        (bool ok,) = address(token)
            .call(abi.encodeWithSignature("mint(address,uint256)", actors[(actorSeed % 3 + 1) % 3], amount));
        assertFalse(ok, "no actor may mint after deployment");
        ++rejectedMintCalls;
    }

    function deferredSell(uint256 actorSeed, uint256 amountSeed, bool twice) external {
        uint256 i = actorSeed % 3;
        uint256 amount = bound(amountSeed, 1, 1e20);
        uint256 beforeBurn = token.balanceOf(DEAD);
        vm.recordLogs();
        vm.prank(actors[i]);
        BalanceDelta delta = openRouter.swapWithMode(
            key,
            _params(false, true, amount),
            twice ? OpenSyncRouter.Mode.Twice : OpenSyncRouter.Mode.Complete,
            1
        );
        uint256 burned = _assertSwapLogs(
            vm.getRecordedLogs(), key, address(manager), address(openRouter), tokenIs0, false, delta
        );
        assertEq(token.balanceOf(DEAD) - beforeBurn, burned, "deferred tax delivered before unlock returns");
        assertEq(_tokenDelta(delta), -int256(amount), "deferred settlement preserves exact input");
        expectedBurn += burned;
        _account(i, delta);
        ++deferredTrades;
    }

    function rejectedDeferredSell(uint256 actorSeed, uint256 amountSeed, bool settleEarly) external {
        uint256 i = actorSeed % 3;
        // A positive tax is required to leave a credit that must be completed.
        uint256 amount = bound(amountSeed, 100, 1e20);
        bytes32 beforeState = _stateDigest(i);
        vm.prank(actors[i]);
        vm.expectRevert(
            settleEarly ? BurnTaxHook.OpenTokenSync.selector : IPoolManager.CurrencyNotSettled.selector
        );
        openRouter.swapWithMode(
            key,
            _params(false, true, amount),
            settleEarly ? OpenSyncRouter.Mode.BeforeSettle : OpenSyncRouter.Mode.Omit,
            1
        );
        assertEq(_stateDigest(i), beforeState, "failed deferred settlement must roll back the swap");
        ++rejectedDeferredTrades;
    }

    function finalizeAgain(uint256 actorSeed) external {
        uint256 i = actorSeed % 3;
        bytes32 beforeState = _stateDigest(i);
        vm.recordLogs();
        vm.startPrank(actors[i]);
        BurnTaxHook(address(key.hooks)).settleBurn();
        BurnTaxHook(address(key.hooks)).settleBurn();
        vm.stopPrank();
        assertEq(vm.getRecordedLogs().length, 0, "completed burns cannot emit or transfer again");
        assertEq(_stateDigest(i), beforeState, "idle finalization cannot consume donations or replay a burn");
        ++finalizations;
    }

    function _trade(uint256 i, uint256 amount, bool buy, bool exactInput, bool prefund) internal {
        uint256 beforeBurn = token.balanceOf(DEAD);
        vm.recordLogs();
        vm.prank(actors[i]);
        BalanceDelta delta = router.swap(
            key, _params(buy, exactInput, amount), 0, type(uint128).max, prefund ? amount * 2 : 0
        );
        uint256 burned = _assertSwapLogs(
            vm.getRecordedLogs(), key, address(manager), address(router), tokenIs0, buy, delta
        );
        assertEq(token.balanceOf(DEAD) - beforeBurn, burned, "dead token balance matches swap tax");
        expectedBurn += burned;
        int256 specified = exactInput
            ? (buy ? _quoteDelta(delta) : _tokenDelta(delta))
            : (buy ? _tokenDelta(delta) : _quoteDelta(delta));
        assertEq(specified, exactInput ? -int256(amount) : int256(amount));
        _account(i, delta);
        ++trades;
    }

    function _account(uint256 i, BalanceDelta delta) internal {
        expectedToken[i] += _tokenDelta(delta);
        expectedQuote[i] += _quoteDelta(delta);
        assertEq(int256(token.balanceOf(actors[i])), expectedToken[i], "actor BTAX ledger");
        assertEq(int256(quote.balanceOf(actors[i])), expectedQuote[i], "actor quote ledger");
    }

    function _params(bool buy, bool exactInput, uint256 amount) internal view returns (SwapParams memory) {
        bool zeroForOne = buy != tokenIs0;
        return SwapParams(
            zeroForOne,
            exactInput ? -int256(amount) : int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function _tokenDelta(BalanceDelta delta) internal view returns (int256) {
        return tokenIs0 ? int256(delta.amount0()) : int256(delta.amount1());
    }

    function _quoteDelta(BalanceDelta delta) internal view returns (int256) {
        return tokenIs0 ? int256(delta.amount1()) : int256(delta.amount0());
    }

    function _stateDigest(uint256 i) internal view returns (bytes32) {
        (uint160 price, int24 tick,,) = manager.getSlot0(key.toId());
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        bytes32 poolState =
            keccak256(abi.encode(price, tick, growth0, growth1, manager.getLiquidity(key.toId())));
        bytes32 settlementState = keccak256(
            abi.encode(
                token.balanceOf(address(key.hooks)),
                token.balanceOf(address(openRouter)),
                quote.balanceOf(address(openRouter)),
                manager.currencyDelta(address(key.hooks), key.currency0),
                manager.currencyDelta(address(key.hooks), key.currency1),
                manager.currencyDelta(address(openRouter), key.currency0),
                manager.currencyDelta(address(openRouter), key.currency1)
            )
        );
        return keccak256(
            abi.encode(
                poolState,
                settlementState,
                token.balanceOf(actors[i]),
                quote.balanceOf(actors[i]),
                token.balanceOf(address(manager)),
                quote.balanceOf(address(manager)),
                token.balanceOf(DEAD),
                manager.balanceOf(DEAD, uint160(address(token))),
                manager.getNonzeroDeltaCount()
            )
        );
    }
}

abstract contract StatefulBurnTaxTests is HookFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    BurnTaxSequenceHandler internal handler;

    function _setupSequences(bool tokenFirst) internal {
        _setup(tokenFirst);
        handler = new BurnTaxSequenceHandler(router, token, quote, key);
        for (uint256 i; i < 3; ++i) {
            token.transfer(handler.actors(i), handler.INITIAL_BALANCE());
            quote.transfer(handler.actors(i), handler.INITIAL_BALANCE());
        }
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.roundTrip.selector;
        selectors[2] = handler.transferOrDonate.selector;
        selectors[3] = handler.changeLiquidity.selector;
        selectors[4] = handler.rejectedTrade.selector;
        selectors[5] = handler.forbiddenMint.selector;
        selectors[6] = handler.deferredSell.selector;
        selectors[7] = handler.rejectedDeferredSell.selector;
        selectors[8] = handler.finalizeAgain.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_supplyAndEveryActorLedgerAreConserved() public view {
        uint256 tokenSum = token.balanceOf(address(this)) + token.balanceOf(address(manager))
            + token.balanceOf(DEAD) + token.balanceOf(address(hook));
        uint256 quoteSum = quote.balanceOf(address(this)) + quote.balanceOf(address(manager));
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            assertEq(int256(token.balanceOf(actor)), handler.expectedToken(i));
            assertEq(int256(quote.balanceOf(actor)), handler.expectedQuote(i));
            tokenSum += token.balanceOf(actor);
            quoteSum += quote.balanceOf(actor);
        }
        assertEq(token.totalSupply(), 1e27);
        assertEq(tokenSum, 1e27);
        assertEq(quoteSum, quote.totalSupply());
        assertEq(token.balanceOf(DEAD), handler.expectedBurn() + handler.donatedToDead());
        assertEq(
            token.balanceOf(address(hook)), handler.donatedToHook(), "hook retains only unsolicited donations"
        );
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_poolSettlesAndLiquidityRemainsWithdrawable() public view {
        assertFalse(IPoolManager(manager).isUnlocked());
        assertEq(IPoolManager(manager).getNonzeroDeltaCount(), 0);
        uint256 liquidity = 1e24;
        for (uint256 i; i < 3; ++i) {
            uint256 expected = handler.positionLiquidity(i);
            (uint128 actual,,) =
                IPoolManager(manager).getPositionInfo(key.toId(), address(router), -600, 600, bytes32(i + 1));
            assertEq(actual, expected);
            liquidity += expected;
        }
        assertEq(IPoolManager(manager).getLiquidity(key.toId()), liquidity);
        (,,, uint24 fee) = IPoolManager(manager).getSlot0(key.toId());
        assertEq(fee, 3000);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(quote.balanceOf(address(router)), 0);
        assertEq(token.balanceOf(address(handler.openRouter())), 0);
        assertEq(quote.balanceOf(address(handler.openRouter())), 0);
        assertEq(quote.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), uint160(address(token))), 0);
        assertEq(manager.balanceOf(DEAD, uint160(address(token))), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(hook), key.currency0), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(hook), key.currency1), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(router), key.currency0), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(router), key.currency1), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(handler.openRouter()), key.currency0), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(handler.openRouter()), key.currency1), 0);
    }

    // End every campaign by exiting all generated LP positions. A view-only liquidity check
    // cannot establish that an actor can actually withdraw after the preceding calls.
    function afterInvariant() public {
        for (uint256 i; i < 3; ++i) {
            if (handler.positionLiquidity(i) != 0) handler.changeLiquidity(i, type(uint256).max, true);
            assertEq(handler.positionLiquidity(i), 0);
        }
        invariant_supplyAndEveryActorLedgerAreConserved();
        invariant_poolSettlesAndLiquidityRemainsWithdrawable();
    }

    function test_allSequenceActionsAreReachable() public {
        for (uint256 i; i < 3; ++i) {
            handler.changeLiquidity(i, 1e21, false);
            for (uint256 mode; mode < 4; ++mode) {
                handler.trade(i, 1 ether, mode % 2 == 0, mode < 2, true);
            }
            handler.roundTrip(i, 1 ether);
            handler.transferOrDonate(i, (i + 1) % 3, 100);
            handler.transferOrDonate(i, 3, 10);
            handler.transferOrDonate(i, 4, 10);
            handler.rejectedTrade(i, 1 ether, true);
            handler.rejectedTrade(i, 1 ether, false);
            handler.forbiddenMint(i, type(uint256).max);
            handler.deferredSell(i, 1 ether, false);
            handler.deferredSell(i, 1 ether, true);
            handler.deferredSell(i, 99, true);
            handler.rejectedDeferredSell(i, 1 ether, false);
            handler.rejectedDeferredSell(i, 1 ether, true);
            handler.finalizeAgain(i);
        }
        afterInvariant();
        assertEq(handler.trades(), 18);
        assertEq(handler.liquidityCalls(), 6);
        assertEq(handler.failedTrades(), 6);
        assertEq(handler.transfers(), 9);
        assertEq(handler.rejectedMintCalls(), 3);
        assertEq(handler.deferredTrades(), 9);
        assertEq(handler.rejectedDeferredTrades(), 6);
        assertEq(handler.finalizations(), 3);
        assertGt(handler.expectedBurn(), 0);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract StatefulBurnTaxToken0Test is StatefulBurnTaxTests {
    function setUp() public {
        _setupSequences(true);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract StatefulBurnTaxToken1Test is StatefulBurnTaxTests {
    function setUp() public {
        _setupSequences(false);
    }
}
