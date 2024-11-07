# Quarto Extension Installer

## Overview

The **Quarto Extension Installer** is a Visual Studio Code extension that allows you to easily install Quarto extensions directly from the [Quarto Extensions Repository](https://github.com/mcanouil/quarto-extensions).
This extension provides a user-friendly interface to browse, select, and install Quarto extensions, enhancing your Quarto development experience.

## Features

- **Browse Extensions**: View a list of available Quarto extensions.
- **Install Extensions**: Install selected Quarto extensions with a single click.
- **Show Output**: View detailed logs of the installation process.

## Requirements

- **Check Internet Connection**: Ensure you have an active internet connection before installing extensions.
- **Check Quarto Installation**: Verify that Quarto is installed and available in your system's PATH.

## Usage

1. Open the Command Palette (`Ctrl+Shift+P` or `Cmd+Shift+P` on macOS).
2. Type `Quarto: Install Extension(s)` and select it.
3. Browse the list of available extensions.
4. Select the extensions you want to install.
5. Answer the prompts to confirm the installation.

## Commands

- `Quarto: Install Extension(s)`: Opens the extension installer interface.
- `Quarto: Show Quarto Extension Installer Output`: Displays the output log for the extension installer.

## Development

### Installation

1. Clone the repository:
    ```sh
    git clone https://github.com/mcanouil/quarto-extensions/tree/main/vscode
    ```
2. Open the project in Visual Studio Code.
3. Install the dependencies:
    ```sh
    npm install
    ```
4. Compile the extension:
    ```sh
    npm run compile
    ```
5. Launch the extension:
    - Press `F5` to open a new VS Code window with the extension loaded.

### Running the Extension

- Open this project in Visual Studio Code.
- Press `F5` to open a new VS Code window with the extension loaded.

### Running Tests

- Open the Command Palette (`Ctrl+Shift+P` or `Cmd+Shift+P` on macOS).
- Type `Tasks: Run Test Task` and select it.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request on the [GitHub repository](https://github.com/mcanouil/quarto-extensions).

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
