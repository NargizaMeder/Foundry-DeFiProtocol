//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";

contract DecentralizedStableCoinTest is Test {
    DecentralizedStableCoin dsc;

    function setUp() public {
        dsc = new DecentralizedStableCoin(address(this));
    }

    function testOnlyOwnerCanMint() public {
        address nonOwner = address(0x123);
        uint256 amountToMint = 100e18;

        vm.prank(nonOwner);
        vm.expectRevert();
        dsc.mint(nonOwner, amountToMint);
    }

    function testOnlyOwnerCanBurn() public {
        uint256 amountToMint = 100e18;
        address owner = dsc.owner();

        vm.prank(owner);
        dsc.mint(owner, amountToMint);

        address nonOwner = address(0x123);
        vm.prank(nonOwner);
        vm.expectRevert();
        dsc.burn(50e18);
    }

    function testRevertIfBurnAmountIsZero() public {
        uint256 amountToMint = 100e18;
        address owner = dsc.owner();

        vm.prank(owner);
        dsc.mint(owner, amountToMint);

        vm.prank(owner);
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
        dsc.burn(0);
    }

    function testRevertIfBurnAmountIsMoreThanBalance() public {
        uint256 amountToMint = 50e18;
        address owner = dsc.owner();

        vm.prank(owner);
        dsc.mint(owner, amountToMint);

        vm.prank(owner);
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__BurnAmountExceedsBalance.selector);
        dsc.burn(100e18);
    }

    function testCannotMintIfAddressIsZero() public {
        address owner = dsc.owner();

        vm.prank(owner);
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__NotZeroAddress.selector);
        dsc.mint(address(0), 100e18);
    }

    function testRevertIfMintAmountIsZero() public {
        address owner = dsc.owner();

        vm.prank(owner);
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
        dsc.mint(address(0x123), 0);
    }

    function testRevertMintAmountIsMoreThanZero() public {
        uint256 amountToMint = 100e18;
        address to = address(0x456);
        address owner = dsc.owner();

        vm.prank(owner);
        bool result = dsc.mint(to, amountToMint);
        assert(result == true);
        assert(dsc.balanceOf(to) == amountToMint);
    }
}
