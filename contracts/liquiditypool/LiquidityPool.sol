pragma solidity ^0.5.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Mintable.sol";
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
    //measured in fUSD
    mapping(address => uint256) public _collateralValue;

    // Debt data
    mapping(address => mapping(address => uint256)) public _debt;
    mapping(address => mapping(address => uint256)) public _debtTokens;
    mapping(address => address[]) public _debtList;
    //measured in fUSD
    mapping(address => uint256) public _debtValue;

    //ftmAddress
    function fAddress() internal pure returns(address) {
        return 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;
    }

    //oracleAddress
    function oAddress() internal pure returns(address) {
        return 0xC17518AE5dAD82B8fc8b56Fe0295881c30848829;
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

    event Mint(
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
        collateralValue = collateralValue.div(2);
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

        uint256 tokenValue = 0;
        tokenValue = IFPrice(oAddress()).getPrice(_token);
        require(tokenValue > 0, "debt token has no value");

        _debt[_token][msg.sender] = _debt[_token][msg.sender].add(_amount);
        _debtTokens[msg.sender][_token] = _debtTokens[msg.sender][_token].add(_amount);
        addDebtToList(_token, msg.sender);

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

    function mint(address _token, uint256 _amount)
        external
        nonReentrant
    {
        require(_amount > 0, "amount must be greater than 0");
        require(_collateralValue[msg.sender] > 0, "collateral must be greater than 0");

        uint256 tokenValue = 0;
        tokenValue = IFPrice(oAddress()).getPrice(_token);
        require(tokenValue > 0, "debt token has no value");

        _debt[_token][msg.sender] = _debt[_token][msg.sender].add(_amount);
        _debtTokens[msg.sender][_token] = _debtTokens[msg.sender][_token].add(_amount);
        addDebtToList(_token, msg.sender);

        uint256 collateralValue = calcCollateralValue(msg.sender);
        uint256 debtValue = calcDebtValue(msg.sender);

        require(collateralValue > debtValue, "insufficient collateral");

        _collateralValue[msg.sender] = collateralValue;
        _debtValue[msg.sender] = debtValue;

        require(_token != fAddress(), "native denom");

        ERC20Mintable(_token).mint(address(this), _amount);
        ERC20(_token).safeTransfer(msg.sender, _amount);

        emit Mint(_token, msg.sender, _amount, block.timestamp);
    }

    function burn(address _token, uint256 _amount)
        external
        payable
        nonReentrant
    {
        require(_amount > 0, "amount must be greater than 0");


        _debt[_token][msg.sender] = _debt[_token][msg.sender].sub(_amount, "insufficient debt outstanding");
        _debtTokens[msg.sender][_token] = _debtTokens[msg.sender][_token].sub(_amount, "insufficient debt outstanding");

        _collateralValue[msg.sender] = calcCollateralValue(msg.sender);
        _debtValue[msg.sender] = calcDebtValue(msg.sender);

        require(_token != fAddress(), "native denom");

        ERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        emit Burn(_token, msg.sender, _amount, block.timestamp);
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

    function liquidate(address _owner)
        external
        nonReentrant
    {
        _collateralValue[_owner] = calcCollateralValue(_owner);
        _debtValue[_owner] = calcDebtValue(_owner);

        require(_collateralValue[_owner] < _debtValue[_owner], "insufficient debt to liquidate");

        for (uint i = 0; i < _collateralList[_owner].length; i++) {
          _collateral[_collateralList[_owner][i]][_owner] = _collateral[_collateralList[_owner][i]][_owner].sub(_collateralTokens[_owner][_collateralList[_owner][i]], "liquidation exceeds balance");
          _collateralTokens[_owner][_collateralList[_owner][i]] = _collateralTokens[_owner][_collateralList[_owner][i]].sub(_collateralTokens[_owner][_collateralList[_owner][i]], "liquidation exceeds balance");
        }

        for (uint i = 0; i < _debtList[_owner].length; i++) {
          _debt[_collateralList[_owner][i]][_owner] = _debt[_collateralList[_owner][i]][_owner].sub(_debt[_owner][_collateralList[_owner][i]], "liquidation exceeds balance");
          _debtTokens[_owner][_collateralList[_owner][i]] = _debtTokens[_owner][_collateralList[_owner][i]].sub(_debtTokens[_owner][_collateralList[_owner][i]], "liquidation exceeds balance");
        }

        _collateralValue[_owner] = calcCollateralValue(_owner);
        _debtValue[_owner] = calcDebtValue(_owner);
    }

    function liquidateToken(address _owner, address _token)
        external
        nonReentrant
    {
        _collateralValue[_owner] = calcCollateralValue(_owner);
        _debtValue[_owner] = calcDebtValue(_owner);

        require(_collateralValue[_owner] < _debtValue[_owner], "insufficient debt to liquidate");

        _collateral[_token][_owner] = _collateral[_token][_owner].sub(_collateralTokens[_owner][_token], "liquidation exceeds balance");
        _collateralTokens[_owner][_token] = _collateralTokens[_owner][_token].sub(_collateralTokens[_owner][_token], "liquidation exceeds balance");

        _debt[_token][_owner] = _debt[_token][_owner].sub(_debt[_owner][_token], "liquidation exceeds balance");
        _debtTokens[_owner][_token] = _debtTokens[_owner][_token].sub(_debtTokens[_owner][_token], "liquidation exceeds balance");

        _collateralValue[_owner] = calcCollateralValue(_owner);
        _debtValue[_owner] = calcDebtValue(_owner);
    }
}
