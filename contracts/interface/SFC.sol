pragma solidity ^0.5.0;

interface SFC {
    function calcDelegationRewards(address delegator, uint256 _fromEpoch, uint256 maxEpochs) external view returns (uint256, uint256, uint256);
    function calcValidatorRewards(uint256 stakerID, uint256 _fromEpoch, uint256 maxEpochs) external view returns (uint256, uint256, uint256);
    function getStakerID(address addr) external view returns (uint256);
}
