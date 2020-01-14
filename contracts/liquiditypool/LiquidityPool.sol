pragma solidity ^0.5.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../OneSplit.sol";

contract LiquidityPool is ReentrancyGuard {
    using SafeMath for uint256;
    using Address for address;

    // Collateral data
    mapping(address => mapping(address => uint)) public _collateral;
    mapping(address => mapping(address => uint)) public _collateralTokens;
    mapping(address => address[]) public _collateralList;
    //measured in ETH - slippage
    mapping(address => uint) public _collateralValue;

    // Debt data
    mapping(address => mapping(address => uint)) public _debt;
    mapping(address => mapping(address => uint)) public _debtTokens;
    mapping(address => address[]) public _debtList;
    //measured in ETH + slippage
    mapping(address => uint) public _debtValue;

    function ethAddress() internal pure returns(address) {
        return 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
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

    function deposit(address _token, uint256 _amount)
        external
        payable
        nonReentrant
    {
        require(_amount > 0, "amount must be greater than 0");


        _collateral[_token][msg.sender] = _collateral[_token][msg.sender].add(_amount);
        _collateralTokens[msg.sender][_token] = _collateralTokens[msg.sender][_token].add(_amount);
        addCollateralToList(_token, msg.sender);
        uint256 collateralValue = 0;
        uint256[] memory results;
        for (uint i = 0; i < _collateralList[msg.sender].length; i++) {
          (results) = OneSplit.getAllRatesForDEX(_collateralList[msg.sender][i], ethAddress(), _collateralTokens[msg.sender][_collateralList[msg.sender][i]], 1, 0);
          collateralValue = collateralValue.add(results[0]);
        }
        _collateralValue[msg.sender] = collateralValue;

        if (_token != ethAddress()) {
            require(msg.value == 0, "user is sending ETH along with the ERC20 transfer.");
            IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
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
        uint256 collateralValue = 0;
        uint256[] memory results;
        for (uint i = 0; i < _collateralList[msg.sender]; i++) {
          (results) = OneSplit.getAllRatesForDEX(_collateralList[msg.sender][i], ethAddress(), _collateralTokens[msg.sender][_collateralList[msg.sender][i]], 1, 0);
          collateralValue = collateralValue.add(results[0]);
        }
        require(collateralValue > _debtValue, "withdraw would liquidate holdings");
        _collateralValue[msg.sender] = collateralValue;
        if (_token != ethAddress()) {
            IERC20(_token).safeTransfer(msg.sender, _amount);
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

        uint256[] memory tokenValue;

        (tokenValue) = OneSplit.getAllRatesForDEX(_token, ethAddress(), _debtTokens[msg.sender][_token], 1, 0);
        require(tokenValue[0] > 0, "debt token has no value");

        uint256 collateralValue = 0;
        uint256[] memory results;
        for (uint i = 0; i < _collateralList[msg.sender]; i++) {
          (results) = OneSplit.getAllRatesForDEX(_collateralList[msg.sender][i], ethAddress(), _collateralTokens[msg.sender][_collateralList[msg.sender][i]], 1, 0);
          collateralValue = collateralValue.add(results[0]);
        }

        uint256 debtValue = 0;
        for (uint i = 0; i < _debtList[msg.sender]; i++) {
          (results) = OneSplit.getAllRatesForDEX(_debtList[msg.sender][i], ethAddress(), _debtTokens[msg.sender][_debtList[msg.sender][i]], 1, 0);
          debtValue = debtValue.add(results[0]);
        }

        require(collateralValue > debtValue, "insufficient collateral");
        _collateralValue[msg.sender] = collateralValue;
        _debtValue[msg.sender] = debtValue;

        if (_token != ethAddress()) {
            IERC20(_token).safeTransfer(msg.sender, _amount);
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

        uint256 collateralValue = 0;
        uint256[] memory results;
        for (uint i = 0; i < _collateralList[msg.sender]; i++) {
          (results) = OneSplit.getAllRatesForDEX(_collateralList[msg.sender][i], ethAddress(), _collateralTokens[msg.sender][_collateralList[msg.sender][i]], 1, 0);
          collateralValue = collateralValue.add(results[0]);
        }

        uint256 debtValue = 0;
        for (uint i = 0; i < _debtList[msg.sender]; i++) {
          (results) = OneSplit.getAllRatesForDEX(_debtList[msg.sender][i], ethAddress(), _debtTokens[msg.sender][_debtList[msg.sender][i]], 1, 0);
          debtValue = debtValue.add(results[0]);
        }

        require(collateralValue > debtValue, "insufficient collateral");
        _collateralValue[msg.sender] = collateralValue;
        _debtValue[msg.sender] = debtValue;

        if (_token != ethAddress()) {
            require(msg.value == 0, "user is sending ETH along with the ERC20 transfer.");
            IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
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
        uint256 collateralValue = 0;
        uint256[] memory results;
        for (uint i = 0; i < _collateralList[_owner]; i++) {
          (results) = OneSplit.getAllRatesForDEX(_collateralList[_owner][i], ethAddress(), _collateralTokens[_owner][_collateralList[_owner][i]], 1, 0);
          collateralValue = collateralValue.add(results[0]);
        }

        uint256 debtValue = 0;
        for (uint i = 0; i < _debtList[_owner]; i++) {
          (results) = OneSplit.getAllRatesForDEX(_debtList[_owner][i], ethAddress(), _debtTokens[_owner][_debtList[_owner][i]], 1, 0);
          debtValue = debtValue.add(results[0]);
        }

        _collateralValue[_owner] = collateralValue;
        _debtValue[_owner] = debtValue;

        require(collateralValue < debtValue, "insufficient debt to liquidate");

        uint256 sold = 0;
        collateralValue = 0;
        for (uint i = 0; i < _collateralList[_owner]; i++) {
          (results) = OneSplit.getAllRatesForDEX(_collateralList[_owner][i], ethAddress(), _collateralTokens[_owner][_collateralList[_owner][i]], 1, 0);
          OneSplit.goodSwap(_collateralList[_owner][i], ethAddress(), _collateralTokens[_owner][_collateralList[_owner][i]], results[0], 1, 0);
          _collateral[_collateralList[_owner][i]][_owner] = _collateral[_collateralList[_owner][i]][_owner].sub(_collateralTokens[_owner][_collateralList[_owner][i]], "liquidation exceeds balance");
          _collateralTokens[_owner][_collateralList[_owner][i]] = _collateralTokens[_owner][_collateralList[_owner][i]].sub(_collateralTokens[_owner][_collateralList[_owner][i]], "liquidation exceeds balance");
          sold = sold.add(results[0]);
          collateralValue = collateralValue.add(results[0]);
        }

        debtValue = 0;
        for (uint i = 0; i < _debtList[_owner]; i++) {
          (results) = OneSplit.getAllRatesForDEX(_debtList[_owner][i], ethAddress(), _debtTokens[_owner][_debtList[_owner][i]], 1, 0);
          sold = sold.sub(results[0]);
          if (sold >= 0) {
            OneSplit.goodSwap(ethAddress(), _debtList[_owner][i], _debtTokens[_owner][_collateralList[_owner][i]], results[0], 1, 0);
            _debt[_collateralList[_owner][i]][_owner] = _debt[_collateralList[_owner][i]][_owner].sub(_debt[_owner][_collateralList[_owner][i]], "liquidation exceeds balance");
            _debtTokens[_owner][_collateralList[_owner][i]] = _debtTokens[_owner][_collateralList[_owner][i]].sub(_debtTokens[_owner][_collateralList[_owner][i]], "liquidation exceeds balance");
            debtValue = debtValue.add(results[0]);
          }
        }
        _collateralValue[_owner] = collateralValue;
        _debtValue[_owner] = debtValue;
    }

    function liquidateToken(address _owner, address _token)
        external
        nonReentrant
    {
        uint256 collateralValue = 0;
        uint256[] memory results;
        for (uint i = 0; i < _collateralList[_owner]; i++) {
          (results) = OneSplit.getAllRatesForDEX(_collateralList[_owner][i], ethAddress(), _collateralTokens[_owner][_token], 1, 0);
          collateralValue = collateralValue.add(results[0]);
        }

        uint256 debtValue = 0;
        for (uint i = 0; i < _debtList[_owner]; i++) {
          (results) = OneSplit.getAllRatesForDEX(_debtList[_owner][i], ethAddress(), _debtTokens[_owner][_token], 1, 0);
          debtValue = debtValue.add(results[0]);
        }

        _collateralValue[_owner] = collateralValue;
        _debtValue[_owner] = debtValue;

        require(collateralValue < debtValue, "insufficient debt to liquidate");

        uint256 sold = 0;
        (results) = OneSplit.getAllRatesForDEX(_token, ethAddress(), _collateralTokens[_owner][_token], 1, 0);
        OneSplit.goodSwap(_token, ethAddress(), _collateralTokens[_owner][_token], results[0], 1, 0);
        _collateral[_token][_owner] = _collateral[_token][_owner].sub(_collateralTokens[_owner][_token], "liquidation exceeds balance");
        _collateralTokens[_owner][_token] = _collateralTokens[_owner][_token].sub(_collateralTokens[_owner][_token], "liquidation exceeds balance");
        sold = sold.add(results[0]);

        (results) = OneSplit.getAllRatesForDEX(_token, ethAddress(), _debtTokens[_owner][_token], 1, 0);
        sold = sold.sub(results[0]);
        if (sold >= 0) {
          OneSplit.goodSwap(ethAddress(), _token, _debtTokens[_owner][_token], results[0], 1, 0);
          _debt[_token][_owner] = _debt[_token][_owner].sub(_debt[_owner][_token], "liquidation exceeds balance");
          _debtTokens[_owner][_token] = _debtTokens[_owner][_token].sub(_debtTokens[_owner][_token], "liquidation exceeds balance");
        }
    }


}
