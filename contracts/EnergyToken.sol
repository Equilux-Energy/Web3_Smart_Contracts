// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/Context.sol";

interface IERC677Receiver {
    function onTokenTransfer(
        address _sender,
        uint _value,
        bytes calldata _data
    ) external;
}

contract EnergyToken is Context, ERC20 {
    constructor(
        string memory name,
        string memory symbol,
        uint256 initialAmmount
    ) ERC20(name, symbol) {
        _mint(msg.sender, initialAmmount * 10 ** decimals());
    }

    // Renamed event to avoid conflict with ERC20 Transfer
    event TransferAndCall(
        address indexed from,
        address indexed to,
        uint value,
        bytes data
    );

    function transferAndCall(
        address to,
        uint value,
        bytes calldata data
    ) public returns (bool) {
        _transfer(_msgSender(), to, value);
        emit TransferAndCall(_msgSender(), to, value, data); // Updated event name
        if (isContract(to)) {
            IERC677Receiver receiver = IERC677Receiver(to);
            receiver.onTokenTransfer(_msgSender(), value, data);
        }
        return true;
    }

    function isContract(address addr) private view returns (bool) {
        uint size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    function burn(uint256 amount) external {
        _burn(_msgSender(), amount);
    }
}
