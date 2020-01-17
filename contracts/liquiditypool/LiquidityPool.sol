pragma solidity ^0.5.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../interface/FPrice.sol";

contract LiquidityPool is ReentrancyGuard {
    using SafeMath for uint256;
    using Address for address;
    using SafeERC20 for ERC20;

    // Collateral data
    mapping(address => mapping(address => uint256)) public _collateral;
    mapping(address => mapping(address => uint256)) public _collateralTokens;
    mapping(address => address[]) public _collateralList;
    //measured in ETH - slippage
    mapping(address => uint256) public _collateralValue;

    // Debt data
    mapping(address => mapping(address => uint256)) public _debt;
    mapping(address => mapping(address => uint256)) public _debtTokens;
    mapping(address => address[]) public _debtList;
    //measured in ETH + slippage
    mapping(address => uint256) public _debtValue;

    //ftmAddress
    function fAddress() internal pure returns(address) {
        return 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;
    }
    //oracleAddress
    function oAddress() internal pure returns(address) {
        return 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;
    }
    function sAddress() internal pure returns(address) {
        return 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;
    }

    function addCollateralToList(address _token, address _owner) internal {
        bool tokenAlreadyAdded = false;
        address[] memory tokenList = _collateralList[_owner];
        for (uint256 i = 0; i < tokenList.length; i++)
            if (tokenList[i] == _token) {
                tokenAlreadyAdded = true;
            }
        if (!tokenAlreadyAdded) _collateralList[_owner].push(_token);
    }

    function addDebtToList(address _token, address _owner) internal {
        bool tokenAlreadyAdded = false;
        address[] memory tokenList = _debtList[_owner];
        for (uint256 i = 0; i < tokenList.length; i++)
            if (tokenList[i] == _token) {
                tokenAlreadyAdded = true;
            }
        if (!tokenAlreadyAdded) _debtList[_owner].push(_token);
    }

    event Deposit(
        address indexed _token,
        address indexed _user,
        uint256 _amount,
        uint256 _timestamp
    );

    event Withdraw(
        address indexed _token,
        address indexed _user,
        uint256 _amount,
        uint256 _timestamp
    );

    event Borrow(
        address indexed _token,
        address indexed _user,
        uint256 _amount,
        uint256 _timestamp
    );

    event Repay(
        address indexed _token,
        address indexed _user,
        uint256 _amount,
        uint256 _timestamp
    );

    function calcCollateralValue(address addr) public view returns(uint256 collateralValue)
    {
        uint256 results = 0;
        for (uint i = 0; i < _collateralList[addr].length; i++) {
          results = IFPrice(oAddress()).getPrice(_collateralList[addr][i]);
          collateralValue = collateralValue.add(results);
        }
    }

    function calcDebtValue(address addr) public view returns(uint256 debtValue)
    {
      uint256 results = 0;
      for (uint i = 0; i < _debtList[addr].length; i++) {
        results = IFPrice(oAddress()).getPrice(_debtList[addr][i]);
        debtValue = debtValue.add(results);
      }
    }

    function deposit(address _token, uint256 _amount)
        external
        payable
        nonReentrant
    {
        require(_amount > 0, "amount must be greater than 0");

        _collateral[_token][msg.sender] = _collateral[_token][msg.sender].add(_amount);
        _collateralTokens[msg.sender][_token] = _collateralTokens[msg.sender][_token].add(_amount);
        addCollateralToList(_token, msg.sender);
        _collateralValue[msg.sender] = calcCollateralValue(msg.sender);

        if (_token != fAddress()) {
            require(msg.value == 0, "user is sending ETH along with the ERC20 transfer.");
            ERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        } else {
            require(msg.value >= _amount, "the amount and the value sent to deposit do not match");
            if (msg.value > _amount) {
                uint256 excessAmount = msg.value.sub(_amount);
                (bool result, ) = msg.sender.call.value(excessAmount).gas(50000)("");
                require(result, "transfer of ETH failed");
            }
        }
        emit Deposit(_token, msg.sender, _amount, block.timestamp);
    }

    function withdraw(address _token, uint256 _amount)
        external
        nonReentrant
    {
        require(_amount > 0, "amount must be greater than 0");
        _collateral[_token][msg.sender] = _collateral[_token][msg.sender].sub(_amount, "withdraw amount exceeds balance");
        _collateralTokens[msg.sender][_token] = _collateralTokens[msg.sender][_token].sub(_amount, "withdraw amount exceeds balance");
        uint256 collateralValue = calcCollateralValue(msg.sender);
        uint256 debtValue = calcDebtValue(msg.sender);
        require(collateralValue > debtValue, "withdraw would liquidate holdings");
        _collateralValue[msg.sender] = collateralValue;
        _debtValue[msg.sender] = debtValue;

        if (_token != fAddress()) {
            ERC20(_token).safeTransfer(msg.sender, _amount);
        } else {
            (bool result, ) = msg.sender.call.value(_amount).gas(50000)("");
            require(result, "transfer of ETH failed");
        }
        emit Withdraw(_token, msg.sender, _amount, block.timestamp);
    }

    function borrow(address _token, uint256 _amount)
        external
        nonReentrant
    {
        require(_amount > 0, "amount must be greater than 0");
        require(_collateralValue[msg.sender] > 0, "collateral must be greater than 0");

        _debt[_token][msg.sender] = _debt[_token][msg.sender].add(_amount);
        _debtTokens[msg.sender][_token] = _debtTokens[msg.sender][_token].add(_amount);
        addDebtToList(_token, msg.sender);

        uint256 tokenValue = 0;
        tokenValue = IFPrice(oAddress()).getPrice(_token);
        require(tokenValue > 0, "debt token has no value");

        uint256 collateralValue = calcCollateralValue(msg.sender);
        uint256 debtValue = calcDebtValue(msg.sender);

        require(collateralValue > debtValue, "insufficient collateral");

        _collateralValue[msg.sender] = collateralValue;
        _debtValue[msg.sender] = debtValue;

        if (_token != fAddress()) {
            ERC20(_token).safeTransfer(msg.sender, _amount);
        } else {
            (bool result, ) = msg.sender.call.value(_amount).gas(50000)("");
            require(result, "transfer of ETH failed");
        }
        emit Borrow(_token, msg.sender, _amount, block.timestamp);
    }

    function repay(address _token, uint256 _amount)
        external
        payable
        nonReentrant
    {
        require(_amount > 0, "amount must be greater than 0");


        _debt[_token][msg.sender] = _debt[_token][msg.sender].sub(_amount, "insufficient debt outstanding");
        _debtTokens[msg.sender][_token] = _debtTokens[msg.sender][_token].sub(_amount, "insufficient debt outstanding");

        _collateralValue[msg.sender] = calcCollateralValue(msg.sender);
        _debtValue[msg.sender] = calcDebtValue(msg.sender);

        if (_token != fAddress()) {
            require(msg.value == 0, "user is sending ETH along with the ERC20 transfer.");
            ERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        } else {
            require(msg.value >= _amount, "the amount and the value sent to deposit do not match");
            if (msg.value > _amount) {
                uint256 excessAmount = msg.value.sub(_amount);
                (bool result, ) = msg.sender.call.value(excessAmount).gas(50000)("");
                require(result, "transfer of ETH failed");
            }
        }

        emit Repay(_token, msg.sender, _amount, block.timestamp);
    }

    /*function liquidate(address _owner)
        external
        nonReentrant
    {
        _collateralValue[_owner] = calcCollateralValue(_owner);
        _debtValue[_owner] = calcDebtValue(_owner);

        require(_collateralValue[_owner] < _debtValue[_owner], "insufficient debt to liquidate");

        uint256 sold = 0;
        uint256 collateralValue = 0;
        uint256 results = 0;
        for (uint i = 0; i < _collateralList[_owner].length; i++) {
          (results,) = OneSplit(sAddress()).getExpectedReturn(ERC20(_collateralList[_owner][i]), ERC20(fAddress()), _collateralTokens[_owner][_collateralList[_owner][i]], 1, 0);
          OneSplit(sAddress()).goodSwap(ERC20(_collateralList[_owner][i]), ERC20(fAddress()), _collateralTokens[_owner][_collateralList[_owner][i]], results, 1, 0);
          _collateral[_collateralList[_owner][i]][_owner] = _collateral[_collateralList[_owner][i]][_owner].sub(_collateralTokens[_owner][_collateralList[_owner][i]], "liquidation exceeds balance");
          _collateralTokens[_owner][_collateralList[_owner][i]] = _collateralTokens[_owner][_collateralList[_owner][i]].sub(_collateralTokens[_owner][_collateralList[_owner][i]], "liquidation exceeds balance");
          sold = sold.add(results);
          collateralValue = collateralValue.add(results);
        }

        uint256 debtValue = 0;
        for (uint i = 0; i < _debtList[_owner].length; i++) {
          (results,) = OneSplit(sAddress()).getExpectedReturn(ERC20(_debtList[_owner][i]), ERC20(fAddress()), _debtTokens[_owner][_debtList[_owner][i]], 1, 0);
          sold = sold.sub(results);
          if (sold >= 0) {
            OneSplit(sAddress()).goodSwap(ERC20(fAddress()), ERC20(_debtList[_owner][i]), _debtTokens[_owner][_collateralList[_owner][i]], results, 1, 0);
            _debt[_collateralList[_owner][i]][_owner] = _debt[_collateralList[_owner][i]][_owner].sub(_debt[_owner][_collateralList[_owner][i]], "liquidation exceeds balance");
            _debtTokens[_owner][_collateralList[_owner][i]] = _debtTokens[_owner][_collateralList[_owner][i]].sub(_debtTokens[_owner][_collateralList[_owner][i]], "liquidation exceeds balance");
            debtValue = debtValue.add(results);
          }
        }
        _collateralValue[_owner] = collateralValue;
        _debtValue[_owner] = debtValue;
    }

    function liquidateToken(address _owner, address _token)
        external
        nonReentrant
    {
        _collateralValue[_owner] = calcCollateralValue(_owner);
        _debtValue[_owner] = calcDebtValue(_owner);

        require(_collateralValue[_owner] < _debtValue[_owner], "insufficient debt to liquidate");

        uint256 sold = 0;
        uint256 results = 0;
        (results,) = OneSplit(sAddress()).getExpectedReturn(ERC20(_token), ERC20(fAddress()), _collateralTokens[_owner][_token], 1, 0);
        OneSplit(sAddress()).goodSwap(ERC20(_token), ERC20(fAddress()), _collateralTokens[_owner][_token], results, 1, 0);
        _collateral[_token][_owner] = _collateral[_token][_owner].sub(_collateralTokens[_owner][_token], "liquidation exceeds balance");
        _collateralTokens[_owner][_token] = _collateralTokens[_owner][_token].sub(_collateralTokens[_owner][_token], "liquidation exceeds balance");
        sold = sold.add(results);

        (results,) = OneSplit(sAddress()).getExpectedReturn(ERC20(_token), ERC20(fAddress()), _debtTokens[_owner][_token], 1, 0);
        sold = sold.sub(results);
        if (sold >= 0) {
          OneSplit(sAddress()).goodSwap(ERC20(fAddress()), ERC20(_token), _debtTokens[_owner][_token], results, 1, 0);
          _debt[_token][_owner] = _debt[_token][_owner].sub(_debt[_owner][_token], "liquidation exceeds balance");
          _debtTokens[_owner][_token] = _debtTokens[_owner][_token].sub(_debtTokens[_owner][_token], "liquidation exceeds balance");
        }
    }*/
}
