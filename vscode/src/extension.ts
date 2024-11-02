import * as vscode from "vscode";
import * as https from "https";
import { IncomingMessage } from "http";

export function activate(context: vscode.ExtensionContext) {
  let disposable = vscode.commands.registerCommand(
    "quartoExtensionInstaller.installExtension",
    async () => {
      const csvUrl =
        "https://raw.githubusercontent.com/mcanouil/quarto-extensions/main/extensions/quarto-extensions.csv";
      let extensionsList: string[] = [];

      try {
        const data = await fetchCSVFromURL(csvUrl);
        extensionsList = data.split("\n").filter((line) => line.trim() !== "");
      } catch (error) {
        vscode.window.showErrorMessage(
          'Error fetching "quarto-extensions.csv" from https:///github.com/mcanouil/quarto-extensions'
        );
        return;
      }

      const selectedExtension = await vscode.window.showQuickPick(
        extensionsList,
        {
          placeHolder: "Select a Quarto extension to install",
        }
      );

      if (selectedExtension) {
        const terminal = vscode.window.createTerminal("Quarto");
        terminal.show();
        terminal.sendText(`quarto add ${selectedExtension}`);
      }
    }
  );

  context.subscriptions.push(disposable);
}

async function fetchCSVFromURL(url: string): Promise<string> {
  return new Promise((resolve, reject) => {
    https
      .get(url, (res: IncomingMessage) => {
        const data: Uint8Array[] = [];

        res.on("data", (chunk: Uint8Array) => {
          data.push(chunk);
        });

        res.on("end", () => {
          const buffer = Buffer.concat(data);
          resolve(buffer.toString("utf8"));
        });

        res.on("error", (err: Error) => {
          reject(err);
        });
      })
      .on("error", (err: Error) => {
        reject(err);
      });
  });
}

export function deactivate() {}
