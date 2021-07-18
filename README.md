<br />
<p align="center">

  <img src="images/pipe.png" alt="Logo" width="100" height="100">
  <h3 align="center">Piped Piper - ETHGlobal Hack Money Hackathon</h3>
</p>

<!-- TABLE OF CONTENTS -->
<details open="open">
  <summary><h2 style="display: inline-block">Table of Contents</h2></summary>
  <ol>
    <li>
      <a href="#about-the-project">About The Project</a>
      <ul>
        <li><a href="#built-with">Built With</a></li>
      </ul>
    </li>
    <li>
      <a href="#getting-started">Getting Started</a>
      <ul>
        <li><a href="#installation">Installation</a></li>
      </ul>
    </li>
    <li><a href="#usage">Usage</a></li>
    <li><a href="#license">License</a></li>
    <li><a href="#contact">Contact</a></li>
  </ol>
</details>

<!-- ABOUT THE PROJECT -->

## About The Project

Our project utilizes Superfluid to create a SuperValve and Pipe contracts which enables users to flow money through the SuperValve and allocate their flow amongst multiple existing yield generating vaults. The Pipe allows the flows to be aggregated and to interface with existing DeFi applications.

### Built With

-   [Superfluid](https://www.superfluid.finance/home)
-   [Solidity](https://soliditylang.org/)
-   [Hardhat](https://hardhat.org/)
-   [TypeScript](https://typescriptlang.org/)

<!-- GETTING STARTED -->

## Getting Started

To get a local copy up and running follow these simple steps.

### Installation

1. Clone the repo
    ```sh
    git clone https://github.com/0xdavinchee/piped-piper.git
    ```
2. Install NPM packages
    ```sh
    npm install
    ```
3. Create a `.env` file and add the two following values:

-   `MNEMONIC`: A mnemonic for accounts
-   `TEST_ACCOUNT_PRIVATE_KEY`: Private key for deployment.
-   `HOST_ADDRESS`: The address of the Superfluid host contract on the network you plan on deploying to.
-   `CFA_ADDRESS`: The address of the Superfluid Constant Flow Agreement V1 contract on the network you plan on deploying to.
-   `INFURA_API_KEY`: You can get this from https://infura.io by signing up for a free account.

<!-- USAGE EXAMPLES -->

## Usage

To compile: `npx hardhat compile`.

To run tests: `npx hardhat test`.

To get test coverage: `npx hardhat coverage`.

To deploy your smart contracts on a network, run `npx hardhat deploy --network <NETWORK>`, you can select one of the networks defined in `hardhat.config.ts`.

To use this with the front end `cd` into the `frontend` folder and run `npm start`. Note: You will need to create a `.env` file with `REACT_APP_SUPER_VALVE_ADDRESS` which is the address of your SuperValve. You can choose to add more SuperValve's in the future by editing the `VALVE_DATA` variable in `PipedPiper.tsx`.

<!-- LICENSE -->

## License

Distributed under the MIT License. See `LICENSE` for more information.

<!-- CONTACT -->

## Contact

Project Link: [https://github.com/0xdavinchee/piped-piper](https://github.com/0xdavinchee/piped-piper)
