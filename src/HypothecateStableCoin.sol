//SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {HypothcateStableCoinErrorsAndEvents} from "./lib/HypothcateStableCoinErrorsAndEvents.sol";

contract HypothecateStableCoin is
    ERC20Burnable,
    Ownable,
    HypothcateStableCoinErrorsAndEvents
{
    constructor(
        address initialOwner
    ) ERC20("HSCOIN", "HSC") Ownable(initialOwner) {}

    /**
     *  销毁稳定币
     * @param amount 销毁的稳定币数量
     */
    function burn(uint256 amount) public override onlyOwner {
        if (amount > balanceOf(msg.sender)) {
            revert Error_HypothecateStableCoin_BurnAmountMustMoreThanBalance();
        }
        if (amount <= 0) {
            revert Error_HypothecateStableCoin_AmountMoreThanZero();
        }
        super.burn(amount);
    }

    /**
     * 铸造稳定币
     * @param to   用户地址
     * @param amount 铸造数量
     */
    function mint(
        address to,
        uint256 amount
    ) external onlyOwner returns (bool) {
        if (to == address(0)) {
            revert Error_HypothecateStableCoin_AddressMustNotBeZero();
        }
        if (amount <= 0) {
            revert Error_HypothecateStableCoin_MintAmountMustMoreThanZero();
        }
        _mint(to, amount);
        return true;
    }
}
