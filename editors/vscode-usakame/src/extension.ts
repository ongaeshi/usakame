import * as vscode from 'vscode';
import { UsakameDecorator } from './decorations';
import { parseUsakameDocument, ParsedUsakameDocument } from './parser';
import {
  updateUsakameDiagnostics,
  UsakameCodeLensProvider,
  UsakameCompletionProvider,
  UsakameHoverProvider,
  UsakameSignatureHelpProvider,
} from './providers';
import { UsakameEditorPanel } from './webviewEditor';

export function activate(context: vscode.ExtensionContext): void {
  const parsedCache = new Map<string, { version: number; parsed: ParsedUsakameDocument }>();

  const getParsedDoc = (doc: vscode.TextDocument): ParsedUsakameDocument => {
    const key = doc.uri.toString();
    const cached = parsedCache.get(key);
    if (cached && cached.version === doc.version) {
      return cached.parsed;
    }
    const isResourceOnly = doc.languageId === 'usakame-spr' || doc.languageId === 'usakame-map';
    const parsed = parseUsakameDocument(doc.getText(), isResourceOnly);
    parsedCache.set(key, { version: doc.version, parsed });
    return parsed;
  };

  const decorator = new UsakameDecorator();
  const diagnostics = vscode.languages.createDiagnosticCollection('usakame');
  const codeLensProvider = new UsakameCodeLensProvider(getParsedDoc);

  const selector: vscode.DocumentSelector = [
    { language: 'ruby' },
    { language: 'usakame-spr' },
    { language: 'usakame-map' },
  ];

  context.subscriptions.push(
    decorator,
    diagnostics,
    vscode.languages.registerCompletionItemProvider(
      selector,
      new UsakameCompletionProvider(getParsedDoc),
      '@',
      '(',
      ',',
      ' ',
      ':'
    ),
    vscode.languages.registerSignatureHelpProvider(
      selector,
      new UsakameSignatureHelpProvider(getParsedDoc),
      '(',
      ','
    ),
    vscode.languages.registerHoverProvider(selector, new UsakameHoverProvider(getParsedDoc)),
    vscode.languages.registerCodeLensProvider(selector, codeLensProvider)
  );

  // Commands
  context.subscriptions.push(
    vscode.commands.registerCommand('usakame.openSpriteEditor', (uri?: vscode.Uri, spriteId?: number) => {
      const targetUri = uri || vscode.window.activeTextEditor?.document.uri;
      if (!targetUri) {
        return;
      }
      UsakameEditorPanel.createOrShow(context.extensionUri, targetUri, getParsedDoc, 'sprite', spriteId ?? 0);
    }),

    vscode.commands.registerCommand('usakame.openPaletteEditor', (uri?: vscode.Uri, palId?: number) => {
      const targetUri = uri || vscode.window.activeTextEditor?.document.uri;
      if (!targetUri) {
        return;
      }
      UsakameEditorPanel.createOrShow(context.extensionUri, targetUri, getParsedDoc, 'palette', palId ?? 1);
    }),

    vscode.commands.registerCommand('usakame.openMapEditor', (uri?: vscode.Uri, mapIdx?: number) => {
      const targetUri = uri || vscode.window.activeTextEditor?.document.uri;
      if (!targetUri) {
        return;
      }
      UsakameEditorPanel.createOrShow(context.extensionUri, targetUri, getParsedDoc, 'map', mapIdx ?? 0);
    }),

    vscode.commands.registerCommand(
      'usakame.openSoundEditor',
      (uri?: vscode.Uri, sfxId?: number, kind?: string) => {
        const targetUri = uri || vscode.window.activeTextEditor?.document.uri;
        if (!targetUri) {
          return;
        }
        UsakameEditorPanel.createOrShow(
          context.extensionUri,
          targetUri,
          getParsedDoc,
          'sound',
          sfxId ?? 0,
          kind ?? 'SFX'
        );
      }
    ),

    vscode.commands.registerCommand('usakame.togglePixelColoring', async () => {
      const cfg = vscode.workspace.getConfiguration('usakame');
      const cur = cfg.get<boolean>('enablePixelColoring', true);
      await cfg.update('enablePixelColoring', !cur, vscode.ConfigurationTarget.Global);
      refreshActiveEditors();
    }),

    vscode.commands.registerCommand('usakame.insertResourceSection', async () => {
      const editor = vscode.window.activeTextEditor;
      if (!editor) {
        return;
      }
      const doc = editor.document;
      const parsed = getParsedDoc(doc);
      if (parsed.hasEndMarker) {
        vscode.window.showInformationMessage('すでに __END__ セクションが存在します。');
        return;
      }
      const lastLine = doc.lineCount - 1;
      const pos = new vscode.Position(lastLine, doc.lineAt(lastLine).text.length);
      const empty16 = Array.from({ length: 16 }, () => '................').join('\n');
      const snippet = `\n\n__END__\n@PALETTE 1\n1: #1D2B53\n3: #008751\nB: #00E436\n7: #FFF1E8\n\n@SPRITE 0 16x16 pal:1\n${empty16}\n`;
      const edit = new vscode.WorkspaceEdit();
      edit.insert(doc.uri, pos, snippet);
      await vscode.workspace.applyEdit(edit);
    }),

    vscode.commands.registerCommand('usakame.runGame', () => {
      const editor = vscode.window.activeTextEditor;
      if (!editor) {
        return;
      }
      const filePath = editor.document.fileName;
      const term =
        vscode.window.terminals.find((t) => t.name === 'Usakame') ||
        vscode.window.createTerminal('Usakame');
      term.show(true);
      term.sendText(`uk run "${filePath}"`);
    })
  );

  const refreshEditor = (editor: vscode.TextEditor | undefined) => {
    if (!editor) {
      return;
    }
    const doc = editor.document;
    if (
      doc.languageId !== 'ruby' &&
      doc.languageId !== 'usakame-spr' &&
      doc.languageId !== 'usakame-map'
    ) {
      return;
    }
    const parsed = getParsedDoc(doc);
    decorator.updateDecorations(editor, parsed);
    updateUsakameDiagnostics(doc, parsed, diagnostics);
  };

  const refreshActiveEditors = () => {
    for (const editor of vscode.window.visibleTextEditors) {
      refreshEditor(editor);
    }
    codeLensProvider.refresh();
  };

  let debounceTimer: NodeJS.Timeout | undefined;
  context.subscriptions.push(
    vscode.window.onDidChangeActiveTextEditor((editor) => {
      refreshEditor(editor);
    }),
    vscode.window.onDidChangeVisibleTextEditors(() => {
      refreshActiveEditors();
    }),
    vscode.workspace.onDidChangeTextDocument((e) => {
      if (debounceTimer) {
        clearTimeout(debounceTimer);
      }
      debounceTimer = setTimeout(() => {
        for (const editor of vscode.window.visibleTextEditors) {
          if (editor.document.uri.toString() === e.document.uri.toString()) {
            refreshEditor(editor);
          }
        }
        codeLensProvider.refresh();
      }, 60);
    }),
    vscode.workspace.onDidCloseTextDocument((doc) => {
      parsedCache.delete(doc.uri.toString());
      diagnostics.delete(doc.uri);
    })
  );

  refreshActiveEditors();
}

export function deactivate(): void {}
