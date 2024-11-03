import * as vscode from "vscode";
import * as https from "https";
import { IncomingMessage } from "http";

const RECENTLY_INSTALLED_QEXT_KEY = "recentlyInstalledExtensions";

interface ExtensionQuickPickItem extends vscode.QuickPickItem {
  url?: string;
}

export function activate(context: vscode.ExtensionContext) {
  let disposable = vscode.commands.registerCommand(
    "quartoExtensionInstaller.installExtension",
    async () => {
      const csvUrl =
        "https://raw.githubusercontent.com/mcanouil/quarto-extensions/main/extensions/quarto-extensions.csv";
      let extensionsList: string[] = [];
      let recentlyInstalled: string[] = context.globalState.get(
        RECENTLY_INSTALLED_QEXT_KEY,
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

      const groupedExtensions: ExtensionQuickPickItem[] = [
        {
          label: "Recently Installed",
          kind: vscode.QuickPickItemKind.Separator,
        },
        ...recentlyInstalled
          .map((ext) => ({
            label: formatExtensionLabel(ext),
            buttons: [
              {
                iconPath: new vscode.ThemeIcon("info"),
                tooltip: "Open GitHub Repository",
              },
            ],
            url: getGitHubLink(ext),
          }))
          .sort((a, b) => a.label.localeCompare(b.label)),
        { label: "All Extensions", kind: vscode.QuickPickItemKind.Separator },
        ...extensionsList
          .map((ext) => ({
            label: formatExtensionLabel(ext),
            buttons: [
              {
                iconPath: new vscode.ThemeIcon("info"),
                tooltip: "Open GitHub Repository",
              },
            ],
            url: getGitHubLink(ext),
          }))
          .sort((a, b) => a.label.localeCompare(b.label)),
      ];

      const quickPick = vscode.window.createQuickPick<ExtensionQuickPickItem>();
      quickPick.items = groupedExtensions;
      quickPick.placeholder = "Select a Quarto extension to install";

      quickPick.onDidTriggerItemButton((e) => {
        const url = e.item.url;
        if (url) {
          vscode.env.openExternal(vscode.Uri.parse(url));
        }
      });

      quickPick.onDidAccept(async () => {
        const selectedExtension = quickPick.selectedItems[0];
        if (
          selectedExtension &&
          selectedExtension.label !== "All Extensions" &&
          selectedExtension.label !== "Recently Installed"
        ) {
          const terminal = vscode.window.createTerminal("Quarto");
          terminal.show();
          const match = selectedExtension.label.match(/\(([^)]+)\)$/);
          terminal.sendText(`quarto add ${match?.[1] ?? ''} --no-prompt`);

          // Update recently installed extensions
          recentlyInstalled = [
            selectedExtension.label,
            ...recentlyInstalled.filter((ext) => ext !== selectedExtension.label),
          ].slice(0, 5);
          context.globalState.update(
            RECENTLY_INSTALLED_QEXT_KEY,
            recentlyInstalled
          );
        }
        quickPick.hide();
      });

      quickPick.show();
    }
  );

  // context.globalState.update(RECENTLY_INSTALLED_QEXT_KEY, []);
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
  return `${formattedRepo} (${ext})`;
}

export function deactivate() {}
