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
        ...createExtensionItems(recentlyInstalled),
        { label: "All Extensions", kind: vscode.QuickPickItemKind.Separator },
        ...createExtensionItems(extensionsList),
      ];

      const quickPick = vscode.window.createQuickPick<ExtensionQuickPickItem>();
      quickPick.items = groupedExtensions;
      quickPick.placeholder = "Select Quarto extensions to install";
      quickPick.canSelectMany = true;
      quickPick.onDidTriggerItemButton((e) => {
        const url = e.item.url;
        if (url) {
          vscode.env.openExternal(vscode.Uri.parse(url));
        }
      });

      quickPick.onDidAccept(async () => {
        const selectedExtensions = quickPick.selectedItems;
        if (selectedExtensions.length > 0) {
          const trustAuthors = await vscode.window.showQuickPick(
            ["Yes", "No"],
            {
              placeHolder: "Do you trust the authors of the selected extension(s)?"
            }
          );
  
          if (trustAuthors !== "Yes") {
            vscode.window.showInformationMessage("Operation cancelled by the user.");
            return;
          }

          const installWorkspace = await vscode.window.showQuickPick(
            ["Yes", "No"],
            {
              placeHolder: "Install the selected extension(s) in the current workspace?"
            }
          );

          if (installWorkspace !== "Yes") {
            vscode.window.showInformationMessage("Operation cancelled by the user.");
            return;
          }

          vscode.window.showInformationMessage("Installing selected extension(s) ...");
          const terminal = vscode.window.createTerminal("Quarto-Extensions");
          terminal.show();
          selectedExtensions.forEach((selectedExtension) => {
            terminal.sendText(`quarto add ${selectedExtension.description} --no-prompt`);
            // Update recently installed extensions
            if (selectedExtension.description !== undefined) {
              recentlyInstalled = [
                selectedExtension.description,
                ...recentlyInstalled.filter(
                  (ext) => ext !== selectedExtension.description
                ),
              ].slice(0, 5);
            }
          });
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

  context.globalState.update(RECENTLY_INSTALLED_QEXT_KEY, []);
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

function createExtensionItems(extensions: string[]): ExtensionQuickPickItem[] {
  return extensions
    .map((ext) => ({
      label: formatExtensionLabel(ext),
      description: ext,
      buttons: [
        {
          iconPath: new vscode.ThemeIcon("github"),
          tooltip: "Open GitHub Repository",
        },
      ],
      url: getGitHubLink(ext),
    }))
    .sort((a, b) => a.label.localeCompare(b.label));
}

export function deactivate() {}
