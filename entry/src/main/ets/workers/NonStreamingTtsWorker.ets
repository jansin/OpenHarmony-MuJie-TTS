import worker, { ThreadWorkerGlobalScope, MessageEvents, ErrorEvent } from '@ohos.worker';

import fs, { ReadOptions } from '@ohos.file.fs';

import { BusinessError } from '@ohos.base';
import { OfflineTts, OfflineTtsConfig, TtsInput, TtsOutput } from 'sherpa_onnx';

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;

let tts: OfflineTts;
let cancelled = false;

interface TtsPartialWorkerMessage {
  msgType: string;
  samples: Float32Array;
  progress: number;
}

interface InitTtsDoneWorkerMessage {
  msgType: string;
  sampleRate: number;
  numSpeakers: number;
  numThreads: number;
}

interface TtsGenerateDoneWorkerMessage {
  msgType: string;
  samples: Float32Array;
}

function mkdir(context: Context, parts: string[]) {
  const sandboxPath: string = context.getApplicationContext().filesDir;
  let d = sandboxPath;
  for (const p of parts) {
    d = d + '/' + p;
    try {
      if (fs.accessSync(d)) {
        continue;
      }
    } catch (_) {
    }
    fs.mkdirSync(d);
  }
}

function copyRawFileDirToSandbox(context: Context, srcDir: string) {
  let mgr = context.resourceManager;
  let allFiles: string[] = mgr.getRawFileListSync(srcDir);
  allFiles = allFiles.map((src) => srcDir + '/' + src);
  try {
    allFiles = [...allFiles, ...mgr.getRawFileListSync('vits-melo-tts-zh_en/dict/pos_dict')
      .map((src) => srcDir + '/pos_dict/' + src)];
    allFiles = allFiles.filter((src) => src !== 'vits-melo-tts-zh_en/dict/pos_dict');
  } catch (_) {
  }

  for (const src of allFiles) {
    const parts: string[] = src.split('/');
    if (parts.length != 1) {
      mkdir(context, parts.slice(0, -1));
    }
    copyRawFileToSandbox(context, src, src);
  }
}

function copyRawFileToSandbox(context: Context, src: string, dst: string) {
  const file = context.resourceManager.getRawFdSync(src);
  let fd = file.fd;
  let readOption: ReadOptions = {
    offset: file.offset,
    length: file.length
  };

  let arrayBuffer = new ArrayBuffer(file.length);
  try {
    fs.readSync(fd, arrayBuffer, readOption);
  } catch (error) {
    let code = (error as BusinessError).code;
    let message = (error as BusinessError).message;
    console.error(`copyRawFileToSandbox failed, code: ${code}, message: ${message}.`);
    return;
  }

  let sandboxPath: string = context.getApplicationContext().filesDir;
  let filepath = sandboxPath + '/' + dst;
  const fp = fs.openSync(filepath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  fs.writeSync(fp.fd, arrayBuffer);
  fs.close(fp.fd);
}

function initTts(context: Context): OfflineTts {
  // vits-melo-tts-zh_en: 中英文离线 TTS
  const modelDir = 'vits-melo-tts-zh_en';
  let modelName = modelDir + '/model.onnx';
  let lexicon = modelDir + '/lexicon.txt';
  let dictDir = 'dict';
  let ruleFsts = 'date.fst,phone.fst,number.fst';
  let ruleFars = '';
  let dataDir = '';

  if (ruleFsts != '') {
    let fsts = ruleFsts.split(',');
    let tmp: string[] = [];
    for (const f of fsts) {
      tmp.push(modelDir + '/' + f);
    }
    ruleFsts = tmp.join(',');
  }

  if (dictDir != '') {
    copyRawFileDirToSandbox(context, modelDir + '/' + dictDir);
    let sandboxPath: string = context.getApplicationContext().filesDir;
    dictDir = sandboxPath + '/' + modelDir + '/' + dictDir;
  }

  const tokens = modelDir + '/tokens.txt';

  const config: OfflineTtsConfig = new OfflineTtsConfig();
  config.model.vits.model = modelName;
  config.model.vits.lexicon = lexicon;
  config.model.vits.tokens = tokens;
  config.model.vits.dataDir = dataDir;
  config.model.vits.dictDir = dictDir;
  config.model.numThreads = 2;
  config.model.debug = true;
  config.ruleFsts = ruleFsts;
  config.ruleFars = ruleFars;

  console.log(`config: ${JSON.stringify(config)}`);

  return new OfflineTts(config, context.resourceManager);
}

interface TtsCallbackData {
  samples: Float32Array;
  progress: number;
}

function callback(data: TtsCallbackData): number {
  const partialMsg: TtsPartialWorkerMessage = {
    msgType: 'tts-generate-partial',
    samples: Float32Array.from(data.samples),
    progress: data.progress,
  };
  workerPort.postMessage(partialMsg);

  return cancelled ? 0 : 1;
}

workerPort.onmessage = (e: MessageEvents) => {
  const msgType = e.data['msgType'] as string;
  console.log(`msg-type: ${msgType}`);
  if (msgType == 'init-tts' && !tts) {
    const context = e.data['context'] as Context;
    tts = initTts(context);
    const initDoneMsg: InitTtsDoneWorkerMessage = {
      msgType: 'init-tts-done',
      sampleRate: tts.sampleRate,
      numSpeakers: tts.numSpeakers,
      numThreads: tts.config.model.numThreads,
    };
    workerPort.postMessage(initDoneMsg);
  }

  if (msgType == 'tts-generate-cancel') {
    cancelled = true;
  }

  if (msgType == 'tts-generate') {
    const text = e.data['text'] as string;
    console.log(`recevied text ${text}`);
    const input: TtsInput = new TtsInput();
    input.text = text;
    input.sid = e.data['sid'] as number;
    input.speed = e.data['speed'] as number;
    input.callback = callback;

    cancelled = false;
    tts.generateAsync(input).then((ttsOutput: TtsOutput) => {
      console.log(`sampleRate: ${ttsOutput.sampleRate}`);

      const doneMsg: TtsGenerateDoneWorkerMessage = {
        msgType: 'tts-generate-done',
        samples: Float32Array.from(ttsOutput.samples),
      };
      workerPort.postMessage(doneMsg);
    });
  }
}

workerPort.onmessageerror = (e: MessageEvents) => {
}

workerPort.onerror = (e: ErrorEvent) => {
}
