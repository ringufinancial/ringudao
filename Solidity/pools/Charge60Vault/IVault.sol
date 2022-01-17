interface IVault {
	function TVL() external view returns (uint256);

	function APR() external view returns (uint256);
}