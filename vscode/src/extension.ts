import * as vscode from "vscode";
import * as https from "https";
import { IncomingMessage } from "http";
import { exec } from "child_process";

const RECENTLY_INSTALLED_QEXT_KEY = "recentlyInstalledExtensions";

const quartoExtensionLog = vscode.window.createOutputChannel('Quarto Extensions');


interface ExtensionQuickPickItem extends vscode.QuickPickItem {
  url?: string;
}

export function activate(context: vscode.ExtensionContext) {
  let disposable = vscode.commands.registerCommand(
    "quartoExtensionInstaller.installExtension",
    async () => {
      const isQuartoAvailable = await checkQuartoVersion();
      if (!isQuartoAvailable) {
        const message = "Quarto is not installed or not available in PATH. Please install Quarto and make sure it is available in PATH.";
        quartoExtensionLog.appendLine(message);
        vscode.window.showErrorMessage(message);
        return;
      }

      const csvUrl =
        "https://raw.githubusercontent.com/mcanouil/quarto-extensions/main/extensions/quarto-extensions.csv";
      let extensionsList: string[] = [];
      let recentlyInstalled: string[] = context.globalState.get(
        RECENTLY_INSTALLED_QEXT_KEY,
        []
      );

      try {
        // const data = await fetchCSVFromURL(csvUrl);
        const data = "mcanouil/quarto-animate\nmcanouil/quarto-elevator\nmcanouil/quarto-github\nmcanouil/quarto-highlight-text"
        extensionsList = data.split("\n").filter((line) => line.trim() !== "");
      } catch (error) {
        const message = `Error fetching "quarto-extensions.csv" from ${csvUrl}`;
        quartoExtensionLog.appendLine(message);
        vscode.window.showErrorMessage(message);
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
      quickPick.matchOnDescription = true;
      quickPick.onDidTriggerItemButton((e) => {
        const url = e.item.url;
        if (url) {
          vscode.env.openExternal(vscode.Uri.parse(url));
        }
      });

      quickPick.onDidAccept(async () => {
        const selectedExtensions = quickPick.selectedItems;
        if (selectedExtensions.length > 0) {
          await installExtensions(
            context,
            selectedExtensions,
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

async function checkQuartoVersion(): Promise<boolean> {
  return new Promise((resolve) => {
    exec("quarto --version;", (error, stdout, stderr) => {
      if (error || stderr) {
        resolve(false);
      } else {
        resolve(stdout.trim().length > 0);
      }
    });
  });
}

async function installQuartoExtension(extension: string): Promise<boolean> {
  quartoExtensionLog.appendLine(`\n\nInstalling ${extension} ...`);
  return new Promise((resolve) => {
    const workspaceFolder = vscode.workspace.workspaceFolders?.[0].uri.fsPath;
    const command = `quarto add ${extension} --no-prompt`;
    exec(command, { cwd: workspaceFolder }, (error, stdout, stderr) => {
      if (stderr) {
        quartoExtensionLog.appendLine(`${stderr}`);
      }
      if (stdout) {
        quartoExtensionLog.appendLine(`${stdout}`);
      }
      if (error) {
        quartoExtensionLog.appendLine(`Error: ${error.message}`);
        resolve(false);
        return;
      }
      resolve(true);
    });
  });
}

async function installExtensions(
  context: vscode.ExtensionContext,
  selectedExtensions: readonly ExtensionQuickPickItem[],
  recentlyInstalled: string[]
) {
  const mutableSelectedExtensions: ExtensionQuickPickItem[] = [
    ...selectedExtensions,
  ];

  const isQuartoAvailable = await checkQuartoVersion();
  if (!isQuartoAvailable) {
    const message = "Quarto is not installed or not available in PATH. Please install Quarto and make sure it is available in PATH.";
    quartoExtensionLog.appendLine(message);
    vscode.window.showErrorMessage(message);
    return;
  }

  const trustAuthors = await vscode.window.showQuickPick(["Yes", "No"], {
    placeHolder: "Do you trust the authors of the selected extension(s)?",
  });
  if (trustAuthors !== "Yes") {
    const message = "Operation cancelled because the authors are not trusted.";
    quartoExtensionLog.appendLine(message);
    vscode.window.showInformationMessage(message);
    return;
  }

  const installWorkspace = await vscode.window.showQuickPick(["Yes", "No"], {
    placeHolder: "Do you want to install the selected extension(s)?",
  });
  if (installWorkspace !== "Yes") {
    const message = "Operation cancelled by the user.";
    quartoExtensionLog.appendLine(message);
    vscode.window.showInformationMessage(message);
    return;
  }

  vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: "Installing selected extension(s)",
      cancellable: true,
    },
    async (progress, token) => {
      token.onCancellationRequested(() => {
        const message = "Operation cancelled by the user.";
        quartoExtensionLog.appendLine(message);
        vscode.window.showInformationMessage(message);
			});

      const installedExtensions: string[] = [];
      const failedExtensions: string[] = [];
      const totalExtensions = mutableSelectedExtensions.length;
      let installedCount = 0;

      for (const selectedExtension of mutableSelectedExtensions) {
        if (selectedExtension.description === undefined) {
          continue;
        }
        const success = await installQuartoExtension(selectedExtension.description);;
        if (success) {
          recentlyInstalled = [
            selectedExtension.description,
            ...recentlyInstalled.filter(
              (ext) => ext !== selectedExtension.description
            ),
          ].slice(0, 5);
          installedExtensions.push(selectedExtension.description);
        } else {
          failedExtensions.push(selectedExtension.description);
        }

        installedCount++;
        progress.report({
          message: `(${installedCount} / ${totalExtensions}) ${selectedExtension.label} ...`,
          increment: (1 / totalExtensions) * 100,
        });
      }

      if (failedExtensions.length > 0) {
        const message = `The following extensions were not installed, try manually with \`quarto add <extension>\`: ${failedExtensions.join(", ")}`;
        quartoExtensionLog.appendLine(message);
        vscode.window.showErrorMessage(message);
      } else {
        const message = `All selected extensions (${installedCount}) were installed successfully.`;
        quartoExtensionLog.appendLine(message);
        vscode.window.showInformationMessage(message);
        quartoExtensionLog.appendLine(`\n\nInstalled Extensions:`);
        installedExtensions.forEach((ext) => {
          quartoExtensionLog.appendLine(` - ${ext}`);
        });
      }
    }
  );

  context.globalState.update(RECENTLY_INSTALLED_QEXT_KEY, [
    ...recentlyInstalled,
  ]);
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
