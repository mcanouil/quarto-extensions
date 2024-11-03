import * as vscode from "vscode";
import * as https from "https";
import { IncomingMessage } from "http";

const RECENTLY_INSTALLED_KEY = "recentlyInstalledExtensions";

export function activate(context: vscode.ExtensionContext) {
  let disposable = vscode.commands.registerCommand(
    "quartoExtensionInstaller.installExtension",
    async () => {
      const csvUrl =
        "https://raw.githubusercontent.com/mcanouil/quarto-extensions/main/extensions/quarto-extensions.csv";
      let extensionsList: string[] = [];
      let recentlyInstalled: string[] = context.globalState.get(
        RECENTLY_INSTALLED_KEY,
        []
      );

      try {
        const data = await fetchCSVFromURL(csvUrl);
        extensionsList = data.split("\n").filter((line) => line.trim() !== "");
      } catch (error) {
        vscode.window.showErrorMessage(
          'Error fetching "quarto-extensions.csv" from https:///github.com/mcanouil/quarto-extensions'
        );
        return;
      }

      const groupedExtensions = [
        {
          label: "Recently Installed",
          kind: vscode.QuickPickItemKind.Separator,
        },
        ...recentlyInstalled
          .map((ext) => ({
            label: formatExtensionLabel(ext),
            description: getGitHubLink(ext),
          }))
          .sort((a, b) => a.label.localeCompare(b.label)),
        { label: "All Extensions", kind: vscode.QuickPickItemKind.Separator },
        ...extensionsList
          .map((ext) => ({
            label: formatExtensionLabel(ext),
            description: getGitHubLink(ext),
          }))
          .sort((a, b) => a.label.localeCompare(b.label)),
      ];

      const selectedExtension = await vscode.window.showQuickPick(
        groupedExtensions,
        {
          placeHolder: "Select a Quarto extension to install",
        }
      );

      if (
        selectedExtension &&
        selectedExtension.label !== "All Extensions" &&
        selectedExtension.label !== "Recently Installed"
      ) {
        const terminal = vscode.window.createTerminal("Quarto");
        terminal.show();
        terminal.sendText(`quarto add ${selectedExtension.label} --no-prompt`);

        // Update recently installed extensions
        recentlyInstalled = [
          selectedExtension.label,
          ...recentlyInstalled.filter((ext) => ext !== selectedExtension.label),
        ].slice(0, 5);
        context.globalState.update(RECENTLY_INSTALLED_KEY, recentlyInstalled);
      }
    }
  );

  context.subscriptions.push(disposable);
}

async function fetchCSVFromURL(url: string): Promise<string> {
  return new Promise((resolve, reject) => {
    https
      .get(url, (res: IncomingMessage) => {
        let data = "";
        res.on("data", (chunk) => {
          data += chunk;
        });
        res.on("end", () => {
          resolve(data);
        });
      })
      .on("error", (err) => {
        reject(err);
      });
  });
}

function getGitHubLink(extension: string): string {
  const [owner, repo] = extension.split("/").slice(0, 2);
  return `https://github.com/${owner}/${repo}`;
}

function formatExtensionLabel(ext: string): string {
  const parts = ext.split("/");
  const repo = parts[1];
  let formattedRepo = repo.replace(/[-_]/g, " ");
  formattedRepo = formattedRepo.replace(/quarto/gi, "").trim();
  formattedRepo = formattedRepo
    .split(" ")
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1).toLowerCase())
    .join(" ");
  return formattedRepo;
}

export function deactivate() {}
