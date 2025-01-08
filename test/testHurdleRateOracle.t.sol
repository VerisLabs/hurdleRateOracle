// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/HurdleRateOracle.sol";

contract HurdleRateOracleTest is Test {
    HurdleRateOracle public oracle;

    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public router;

    address owner;
    address user;

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");
        router = makeAddr("router"); // Store router address

        vm.startPrank(owner);
        oracle = new HurdleRateOracle(
            router, // Use stored router address
            1,
            "source code"
        );
        vm.stopPrank();
    }

    // Test initial state and constructor
    function test_InitialState() public {
        assertEq(oracle.paused(), false);
        assertEq(oracle.subscriptionId(), 1);
        assertEq(oracle.currentRates(), 0);

        // Check initial token registrations
        (uint16 wethRate, ) = oracle.getRate(WETH);
        (uint16 usdcRate, ) = oracle.getRate(USDC);
        assertEq(wethRate, 0);
        assertEq(usdcRate, 0);
    }

    // Test token registration
    function test_TokenRegistration() public {
        vm.startPrank(owner);
        address newToken = makeAddr("newToken");
        oracle.registerToken(newToken, 2);
        vm.stopPrank();

        (uint16 rate, ) = oracle.getRate(newToken);
        assertEq(rate, 0);
    }

    // Test token registration failures
    function test_TokenRegistration_Revert() public {
        vm.startPrank(owner);

        // Test zero address
        vm.expectRevert(HurdleRateOracle.AddressZero.selector);
        oracle.registerToken(address(0), 2);

        // Test invalid position
        vm.expectRevert(
            abi.encodeWithSelector(
                HurdleRateOracle.InvalidPosition.selector,
                16
            )
        );
        oracle.registerToken(makeAddr("token"), 16);

        // Test already registered position
        vm.expectRevert(HurdleRateOracle.TokenAlreadyRegistered.selector);
        oracle.registerToken(makeAddr("token"), 0); // Position 0 is taken by WETH

        vm.stopPrank();
    }

    // Test pause functionality
    function test_Pause() public {
        vm.prank(owner);
        oracle.setPause(true);
        assertTrue(oracle.paused());

        vm.prank(owner);
        oracle.setPause(false);
        assertFalse(oracle.paused());
    }

    // Test rate bitmap operations
    function testFuzz_GetBitmap(uint16[] calldata rates) public {
        vm.assume(rates.length <= 16);
        for (uint256 i = 0; i < rates.length; i++) {
            vm.assume(rates[i] <= oracle.MAX_RATE_BPS());
        }

        uint256 bitmap = oracle.getBitmap(rates);

        for (uint256 i = 0; i < rates.length; i++) {
            assertEq(uint16((bitmap >> (i * 16)) & 0xFFFF), rates[i]);
        }
    }

    // Test rate retrieval functions
    function test_RateRetrieval() public {
        uint16 rate = oracle.getRateByPosition(0);
        assertEq(rate, 0);

        (uint16 wethRate, uint256 timestamp) = oracle.getRate(WETH);
        assertEq(wethRate, 0);
    }

    // Test access control
    function test_AccessControl() public {
        vm.prank(user);
        vm.expectRevert("Only callable by owner");
        oracle.registerToken(makeAddr("token"), 2);

        vm.prank(user);
        vm.expectRevert("Only callable by owner");
        oracle.setPause(true);
    }

    function test_SourceValidation() public {
        vm.startPrank(owner);

        // Test empty source
        vm.expectRevert(HurdleRateOracle.InvalidSource.selector);
        oracle.setSource("");

        // Test valid source update
        oracle.setSource("new source");

        vm.stopPrank();
    }

    function test_SubscriptionIdValidation() public {
        vm.startPrank(owner);

        // Test zero subscriptionId
        vm.expectRevert(HurdleRateOracle.InvalidSubscriptionId.selector);
        oracle.setSubscriptionId(0);

        // Get current subscriptionId first
        uint64 currentId = oracle.subscriptionId();

        // Then set up revert expectation
        vm.expectRevert(HurdleRateOracle.InvalidSubscriptionId.selector);
        oracle.setSubscriptionId(currentId);

        // Test valid update
        oracle.setSubscriptionId(2);
        assertEq(oracle.subscriptionId(), 2);

        vm.stopPrank();
    }

    function test_PositionBoundaries() public {
        vm.startPrank(owner);

        // Test position 15 (max valid)
        oracle.registerToken(makeAddr("token15"), 15);

        // Test position 16 (invalid)
        vm.expectRevert(
            abi.encodeWithSelector(
                HurdleRateOracle.InvalidPosition.selector,
                16
            )
        );
        oracle.registerToken(makeAddr("token16"), 16);

        vm.stopPrank();
    }

    function test_GetRateByPosition_Boundaries() public {
        // Test invalid position
        vm.expectRevert(
            abi.encodeWithSelector(
                HurdleRateOracle.InvalidPosition.selector,
                16
            )
        );
        oracle.getRateByPosition(16);

        // Test unregistered but valid position
        uint16 rate = oracle.getRateByPosition(15);
        assertEq(rate, 0);
    }

    function test_ComplexBitmap() public {
        uint16[] memory rates = new uint16[](16);
        rates[0] = 100; // 1%
        rates[15] = 10000; // 100%

        uint256 bitmap = oracle.getBitmap(rates);

        // Verify first and last positions
        assertEq(uint16(bitmap & 0xFFFF), 100);
        assertEq(uint16(bitmap >> 240), 10000);
    }

    function test_RateOverflow() public {
        uint16[] memory rates = new uint16[](1);
        rates[0] = oracle.MAX_RATE_BPS() + 1;

        vm.expectRevert(HurdleRateOracle.InvalidRates.selector);
        oracle.getBitmap(rates);
    }
}
