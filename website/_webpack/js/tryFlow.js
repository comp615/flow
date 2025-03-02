/**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

// defines window.requirejs
import './require_2_3_3';

import * as LZString from 'lz-string';
import {INITIAL, Registry, parseRawGrammar} from 'vscode-textmate';
import {createOnigScanner, createOnigString, loadWASM} from 'vscode-oniguruma';
import {load as initFlowLocally} from './flow-loader';
import THEME from './light_vs';

requirejs.config({
  baseUrl: '/assets',
  waitSeconds: 30,
  paths: {
    'vs': 'https://unpkg.com/monaco-editor@0.26.1/min/vs',
  }
});

function appendMsg(container, msg, editor) {
  const clickHandler = (msg) => {
    editor.getDoc().setSelection(
      {line: msg.loc.start.line - 1, ch: msg.loc.start.column - 1},
      {line: msg.loc.end.line - 1, ch: msg.loc.end.column}
    );
    editor.focus();
  };

  if (msg.loc && msg.context != null) {
    const div = document.createElement('div');
    const basename = msg.loc.source.replace(/.*\//, '');
    const filename = basename !== '-' ? `${msg.loc.source}:` : '';
    const prefix = `${filename}${msg.loc.start.line}: `;

    const before = msg.context.slice(0, msg.loc.start.column - 1);
    const highlight = (msg.loc.start.line === msg.loc.end.line) ?
      msg.context.slice(msg.loc.start.column - 1, msg.loc.end.column) :
      msg.context.slice(msg.loc.start.column - 1);
    const after = (msg.loc.start.line === msg.loc.end.line) ?
      msg.context.slice(msg.loc.end.column) :
      '';
    div.appendChild(document.createTextNode(prefix + before));
    const bold = document.createElement('strong');
    bold.className = "msgHighlight";
    bold.appendChild(document.createTextNode(highlight));
    div.appendChild(bold);
    div.appendChild(document.createTextNode(after));
    container.appendChild(div);

    const offset = msg.loc.start.column + prefix.length - 1;
    const arrow = `${(prefix + before).replace(/[^ ]/g, ' ')}^ `;
    container.appendChild(document.createTextNode(arrow));

    const span = document.createElement('span');
    span.className = "msgType";
    span.appendChild(document.createTextNode(msg.descr));
    container.appendChild(span);

    const handler = clickHandler.bind(null, msg);
    bold.addEventListener('click', handler);
    span.addEventListener('click', handler);
  } else if (msg.type === "Comment") {
    const descr = `. ${msg.descr}\n`;
    container.appendChild(document.createTextNode(descr));
  } else {
    const descr = `${msg.descr}\n`;
    container.appendChild(document.createTextNode(descr));
  }
};

function printExtra(info, editor) {
  const list = document.createElement('ul');
  if (info.message) {
    const li = document.createElement('li');
    info.message.forEach(msg => appendMsg(li, msg, editor));
    list.appendChild(li);
  }
  if (info.children) {
    const li = document.createElement('li');
    info.children.forEach(info => {
      li.appendChild(printExtra(info, editor));
    });
    list.appendChild(li);
  }
  return list;
}

function printError(err, editor) {
  const li = document.createElement('li');
  err.message.forEach(msg => appendMsg(li, msg, editor));

  if (err.extra) {
    err.extra.forEach(info => {
      li.appendChild(printExtra(info, editor));
    });
  }

  return li;
}

function printErrors(errors, editor) {
  const list = document.createElement('ul');
  errors.forEach(err => {
    list.appendChild(printError(err, editor));
  });
  return list;
}

function removeChildren(node) {
  while (node.lastChild) node.removeChild(node.lastChild);
}

function asSeverity(severity) {
  switch (severity) {
    case 'error':
      return monaco.MarkerSeverity.Error;
    case 'warning':
      return monaco.MarkerSeverity.Warning;
    default:
      return monaco.MarkerSeverity.Hint;
  }
}

function validate(flowProxy, model, callback) {
  Promise.resolve(flowProxy)
  .then(flowProxy => flowProxy.checkContent(model.uri.fsPath, model.getValue()))
  .then(errors => {
    const markers = errors.map(err => {
      var messages = err.message;
      var firstLoc = messages[0].loc;
      var message = messages.map(msg => msg.descr).join("\n");
      return {
        // the code is also in the message, so don't also include it here.
        // but if we fixed the message, we'd do this:
        // code: Array.isArray(err.error_codes) ? err.error_codes[0] : undefined,
        severity: asSeverity(err.level),
        message: message,
        source: firstLoc.source,
        startLineNumber: firstLoc.start.line,
        startColumn: firstLoc.start.column,
        endLineNumber: firstLoc.end.line,
        endColumn: firstLoc.end.column + 1,
        // TODO: show references
        // relatedInformation: ...
      };
    });
    monaco.editor.setModelMarkers(model, 'default', markers);
    if (callback != null) {
      callback(errors);
    }
  });
}

const lastEditorValue = localStorage.getItem('tryFlowLastContent');
const defaultValue = (lastEditorValue && getHashedValue(lastEditorValue)) || `/* @flow */

function foo(x: ?number): string {
  if (x) {
    return x;
  }
  return "default string";
}
`;

function getHashedValue(hash) {
  if (hash[0] !== '#' || hash.length < 2) return null;
  const version = hash.slice(1, 2);
  const encoded = hash.slice(2);
  if (version === '0' && encoded.match(/^[a-zA-Z0-9+/=_-]+$/)) {
    return LZString.decompressFromEncodedURIComponent(encoded);
  }
  return null;
}

function removeClass(elem, className) {
  elem.className = elem.className.split(/\s+/).filter(function(name) {
    return name !== className;
  }).join(' ');
}

class Deferred {
  constructor() {
    this.promise = new Promise((resolve, reject) => {
      this.resolve = resolve;
      this.reject = reject;
    });
  }
}

const workerRegistry = {}
class FlowWorker {
  constructor(version) {
    this._version = version;
    this._pending = {};
    this._index = 0;

    const worker = this._worker = new Worker(window.tryFlowWorker);
    worker.onmessage = ({data}) => {
      if (data.id && this._pending[data.id]) {
        if (data.err) {
          this._pending[data.id].reject(data.err);
        } else {
          this._pending[data.id].resolve(data.result);
        }
        delete this._pending[data.id];
      }
    };
    worker.onerror = function() {
      console.log('There is an error with your worker!');
    };

    // keep a reference to the worker, so that it doesn't get GC'd and killed.
    workerRegistry[version] = worker;
  }

  send(data) {
    const id = ++this._index;
    const version = this._version;
    this._pending[id] = new Deferred();
    this._worker.postMessage({ id, version, ...data });
    return this._pending[id].promise;
  }
}

function initFlowWorker(version) {
  const worker = new FlowWorker(version);
  return worker.send({ type: 'init' }).then(() => worker);
}

class AsyncLocalFlow {
  constructor(flow) {
    this._flow = flow;
  }

  checkContent(filename, body) {
    return Promise.resolve(this._flow.checkContent(filename, body));
  }

  typeAtPos(filename, body, line, col) {
    return Promise.resolve(this._flow.typeAtPos(filename, body, line, col));
  }

  supportsParse() {
    return Promise.resolve(this._flow.parse != null);
  }

  parse(body, options) {
    return Promise.resolve(this._flow.parse(body, options));
  }
}

class AsyncWorkerFlow {
  constructor(worker) {
    this._worker = worker;
  }

  checkContent(filename, body) {
    return this._worker.send({ type: 'checkContent', filename, body });
  }

  typeAtPos(filename, body, line, col) {
    return this._worker.send({ type: 'typeAtPos', filename, body, line, col });
  }

  supportsParse() {
    return this._worker.send({ type: 'supportsParse' });
  }

  parse(body, options) {
    return this._worker.send({ type: 'parse', body, options });
  }
}

function initFlow(version) {
  const useWorker = localStorage.getItem('tryFlowUseWorker');
  if (useWorker === 'true') {
    return initFlowWorker(version).then((flow) => new AsyncWorkerFlow(flow));
  } else {
    return initFlowLocally(version).then((flow) => new AsyncLocalFlow(flow));
  }
}

const grammars = {
  'source.js': '/static/syntaxes/flow-grammar.json',
  'source.regexp.flow': '/static/syntaxes/flow-regex-grammar.json',
};

const registry =
  import('vscode-oniguruma/release/onig.wasm')
  .then(wasmModule => fetch(wasmModule.default))
  // manually convert to an ArrayBuffer because Jekyll 3.x doesn't
  // support serving .wasm as application/wasm via `jekyll serve`.
  // Fixed in Jekyll 4
  .then(response => response.arrayBuffer())
  .then(data => {
    loadWASM(data);
  }).then(() => {
    return new Registry({
      onigLib: Promise.resolve({
        createOnigScanner,
        createOnigString,
      }),
      loadGrammar: (scopeName) => {
        if (grammars.hasOwnProperty(scopeName)) {
          const url = grammars[scopeName];
          return fetch(url).then(response => response.json());
        }
        console.error(`Unknown scope name: ${scopeName}`);
        return null;
      },
      theme: THEME
    });
  });

function createTokensProvider(languageId) {
  return (
    registry
    .then(registry => registry.loadGrammarWithConfiguration('source.js', languageId, {}))
    .then(grammar => {
      if (grammar == null) {
        throw Error(`no grammar for ${scopeName}`);
      }

      return {
        getInitialState() {
          return INITIAL;
        },

        tokenizeEncoded(line, state) {
          const tokenizeLineResult2 = grammar.tokenizeLine2(line, state);
          const endState = tokenizeLineResult2.ruleStack;
          const {tokens} = tokenizeLineResult2;
          return {tokens, endState};
        },
      };
    })
  );
}

export function createEditor(
  flowVersion,
  domNode,
  resultsNode,
  flowVersions
) {
  const state = {flow: initFlow(flowVersion)};

  requirejs(["vs/editor/editor.main"], function() {
    const location = window.location;

    state.flow.then(function() {
      removeClass(resultsNode, 'show-loading');
    });

    const headNode = document.getElementsByTagName('head')[0];
    const styles = document.createElement('style');
    styles.type = 'text/css';
    styles.media = 'screen';
    headNode.appendChild(styles);

    const errorsTabNode = document.createElement('li');
    errorsTabNode.className = "tab errors-tab";
    errorsTabNode.appendChild(document.createTextNode('Errors'));
    errorsTabNode.addEventListener('click', function(evt) {
      removeClass(resultsNode, 'show-json');
      removeClass(resultsNode, 'show-ast');
      resultsNode.className += ' show-errors';
      evt.preventDefault();
    });

    const jsonTabNode = document.createElement('li');
    jsonTabNode.className = "tab json-tab";
    jsonTabNode.appendChild(document.createTextNode('JSON'));
    jsonTabNode.addEventListener('click', function(evt) {
      removeClass(resultsNode, 'show-errors');
      removeClass(resultsNode, 'show-ast');
      resultsNode.className += ' show-json';
      evt.preventDefault();
    });

    const astTabNode = document.createElement('li');
    astTabNode.className = "tab ast-tab";
    astTabNode.appendChild(document.createTextNode('AST'));
    astTabNode.addEventListener('click', function(evt) {
      removeClass(resultsNode, 'show-errors');
      removeClass(resultsNode, 'show-json');
      resultsNode.className += ' show-ast';
      evt.preventDefault();
    });

    const versionSelector = document.createElement('select');
    flowVersions.forEach(
      function(version) {
        const option = document.createElement('option');
        option.value = version;
        option.text = version;
        option.selected = version == flowVersion;
        versionSelector.add(option, null);
      }
    );
    const versionTabNode = document.createElement('li');
    versionTabNode.className = "version";
    versionTabNode.appendChild(versionSelector);

    const toolbarNode = document.createElement('ul');
    toolbarNode.className = "toolbar";
    toolbarNode.appendChild(errorsTabNode);
    toolbarNode.appendChild(jsonTabNode);
    toolbarNode.appendChild(astTabNode);
    toolbarNode.appendChild(versionTabNode);

    const errorsNode = document.createElement('pre');
    errorsNode.className = "errors";

    const jsonNode = document.createElement('pre');
    jsonNode.className = "json";

    const astNode = document.createElement('pre');
    astNode.className = "ast";

    resultsNode.appendChild(toolbarNode);
    resultsNode.appendChild(errorsNode);
    resultsNode.appendChild(jsonNode);
    resultsNode.appendChild(astNode);

    resultsNode.className += " show-errors";

    const cursorPositionNode = document.querySelector('footer .cursor-position');
    const typeAtPosNode = document.querySelector('footer .type-at-pos');

    function onFlowErrors(errors) {
      if (errorsNode) {
        if (errors.length) {
          removeChildren(errorsNode);
          errorsNode.appendChild(printErrors(errors, editor));
        } else {
          errorsNode.innerText = 'No errors!';
        }
      }

      if (jsonNode) {
        removeChildren(jsonNode);
        jsonNode.appendChild(
          document.createTextNode(JSON.stringify(errors, null, 2))
        );
      }

      if (astNode) {
        state.flow
        .then((flowProxy) => {
          flowProxy.supportsParse()
          .then(supportsParse => {
            if (supportsParse) {
              const options = {
                esproposal_class_instance_fields: true,
                esproposal_class_static_fields: true,
                esproposal_decorators: true,
                esproposal_export_star_as: true,
                esproposal_optional_chaining: true,
                esproposal_nullish_coalescing: true,
                types: true,
              };
              flowProxy.parse(editor.getValue(), options).then(ast => {
                removeChildren(astNode);
                astNode.appendChild(
                  document.createTextNode(JSON.stringify(ast, null, 2))
                );
                astNode.dataset.disabled = "false";
              });
            } else if (astNode.dataset.disabled !== "true") {
              astNode.dataset.disabled = "true";
              removeChildren(astNode);
              astNode.appendChild(
                document.createTextNode(
                  "AST output is not supported in this version of Flow."
                )
              );
            }
          })
        });
      }
    }

    monaco.languages.register({
      id: 'flow',
      extensions: ['.js', '.flow'],
      aliases: ['Flow'],
    });

    fetch('/static/syntaxes/flow-configuration.json')
    .then(response => response.json())
    .then(config => monaco.languages.setLanguageConfiguration('flow', config));

    const languageId = monaco.languages.getEncodedLanguageId('flow');
    monaco.languages.setTokensProvider('flow', createTokensProvider(languageId));

    registry.then(registry => {
      const colors = registry.getColorMap();
      styles.innerHTML = generateTokensCSSForColorMap(colors);
    });

    const model = monaco.editor.createModel(
      getHashedValue(location.hash) || defaultValue,
      'flow',
      monaco.Uri.file('-'),
    );

    const editor = monaco.editor.create(domNode, {
      model: model,
      minimap: { enabled: false },
      scrollBeyondLastLine: false,
      overviewRulerBorder: false,
      theme: 'vs-light',
    });

    // typecheck on load
    validate(state.flow, model, onFlowErrors);

    model.onDidChangeContent(() => {
      const value = model.getValue();

      // typecheck on edit
      validate(state.flow, model, onFlowErrors);

      // update the URL
      const encoded = LZString.compressToEncodedURIComponent(value);
      history.replaceState(undefined, undefined, `#0${encoded}`);
      localStorage.setItem('tryFlowLastContent', location.hash);
    });

    editor.onDidChangeCursorPosition((event) => {
      const cursor = event.position;
      const value = editor.getModel().getValue();
      cursorPositionNode.innerHTML = `${cursor.lineNumber}:${cursor.column}`;
      state.flow
      .then(flowProxy => flowProxy.typeAtPos(
        '-', value, cursor.lineNumber, cursor.column - 1
      ))
      .then(result => {
        // flow.js <= 0.125 incorrectly returned an ocaml string
        // instead of a JS string, where the string value is hidden in a
        // `c` property.
        var typeAtPos = typeof result === "string"
          ? result
          : result.c;
        typeAtPosNode.title = typeAtPos;
        typeAtPosNode.textContent = typeAtPos;
      })
      .catch(() => {
        typeAtPosNode.title = '';
        typeAtPosNode.textContent = '';
      });
    });

    versionTabNode.addEventListener('change', function(evt) {
      const version = evt.target.value;
      resultsNode.className += ' show-loading';
      state.flow = initFlow(version);
      state.flow.then(function() {
        removeClass(resultsNode, 'show-loading');
      });
      validate(state.flow, model, onFlowErrors);
    });
  });
}

// from https://github.com/microsoft/vscode/blob/013501950e78b9dde5c2e6ec3f2ddfb9201156b7/src/vs/editor/common/modes/supports/tokenization.ts#L398
function generateTokensCSSForColorMap(colorMap) {
  let rules = [];
  for (let i = 1, len = colorMap.length; i < len; i++) {
    let color = colorMap[i];
    // CUSTOM: .code is Try Flow's parent component. we make it more specific to override Monaco
    rules[i] = `.code .mtk${i} { color: ${color}; }`;
  }
  rules.push('.code .mtki { font-style: italic; }');
  rules.push('.code .mtkb { font-weight: bold; }');
  rules.push('.code .mtku { text-decoration: underline; text-underline-position: under; }');
  return rules.join('\n');
}
