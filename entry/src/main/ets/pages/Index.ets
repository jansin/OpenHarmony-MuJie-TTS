import worker, { MessageEvents } from '@ohos.worker';
import audio from '@ohos.multimedia.audio';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import systemTime from '@ohos.systemTime';
import { CircularBuffer } from 'sherpa_onnx';

interface TtsWorkerOptions {
  name: string;
}

interface InitTtsWorkerMessage {
  msgType: string;
  context: Context;
}

interface TtsGenerateWorkerMessage {
  msgType: string;
  text: string;
  sid: number;
  speed: number;
}

interface TtsCancelWorkerMessage {
  msgType: string;
}

function savePcmToWav(filename: string, samples: Int16Array, sampleRate: number) {
  try {
    const fp = fs.openSync(filename, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
    const header = new ArrayBuffer(44);
    const view = new DataView(header);

    view.setUint32(0, 0x46464952, true);
    view.setUint32(4, 36 + samples.length * 2, true);
    view.setUint32(8, 0x45564157, true);
    view.setUint32(12, 0x20746d66, true);
    view.setUint32(16, 16, true);
    view.setUint32(20, 1, true);
    view.setUint16(22, 1, true);
    view.setUint32(24, sampleRate, true);
    view.setUint32(28, sampleRate * 2, true);
    view.setUint16(32, 2, true);
    view.setUint16(34, 16, true);
    view.setUint32(36, 0x61746164, true);
    view.setUint32(40, samples.length * 2, true);

    fs.writeSync(fp.fd, new Uint8Array(header).buffer, { length: header.byteLength });
    fs.writeSync(fp.fd, samples.buffer, { length: samples.buffer.byteLength });
    fs.closeSync(fp.fd);
  } catch (e) {
    console.error('savePcmToWav failed: ' + JSON.stringify(e));
  }
}

function toInt16Samples(samples: Float32Array): Int16Array {
  const int16Samples = new Int16Array(samples.length);
  for (let i = 0; i < samples.length; ++i) {
    let s = samples[i] * 32767;
    s = s > 32767 ? 32767 : s;
    s = s < -32768 ? -32768 : s;
    int16Samples[i] = s;
  }

  return int16Samples;
}

@Entry
@Component
struct Index {
  @State title: string = '离线文字转语音';
  @State info: string = '';
  @State btnStartCaption: string = '开始朗读';
  @State btnStartEnabled: boolean = false;
  @State btnStopCaption: string = '停止';
  @State btnStopEnabled: boolean = false;
  @State btnSaveCaption: string = '保存';
  @State btnSaveEnabled: boolean = false;
  @State progress: number = 0;
  @State sid: string = '0';
  @State speechSpeed: string = '1.0';
  @State isGenerating: boolean = false;
  @State initTtsDone: boolean = false;
  @State ttsGeneratedDone: boolean = true;
  @State numSpeakers: number = 1;
  @State numThreads: number = 1;
  @State initAudioDone: boolean = false;
  @State isPlaying: boolean = false;
  private cancelled: boolean = false;
  private pendingPlaybackStart: boolean = false;
  private sampleRate: number = 0;
  private startTime: number = 0;
  private stopTime: number = 0;
  private inputText: string = '';
  private workerInstance?: worker.ThreadWorker
  private readonly scriptURL: string = 'entry/ets/workers/NonStreamingTtsWorker.ets'
  private sampleBuffer: CircularBuffer = new CircularBuffer(16000 * 5);
  private finalSamples: Float32Array | null = null;
  private audioRenderer: audio.AudioRenderer | null = null;

  initAudioRenderer(onReady?: () => void) {
    if (this.sampleRate <= 0) {
      return;
    }
    if (this.audioRenderer) {
      onReady?.();
      return;
    }

    const audioStreamInfo: audio.AudioStreamInfo = {
      samplingRate: this.sampleRate,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };

    const audioRendererInfo: audio.AudioRendererInfo = {
      usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
      rendererFlags: 0
    };

    const audioRendererOptions: audio.AudioRendererOptions = {
      streamInfo: audioStreamInfo,
      rendererInfo: audioRendererInfo
    };

    audio.createAudioRenderer(audioRendererOptions, (err, renderer) => {
      if (!err && renderer) {
        this.initAudioDone = true;
        this.audioRenderer = renderer;
        this.audioRenderer.on('writeData', this.audioPlayCallback);
        if (this.pendingPlaybackStart || this.sampleBuffer.size() > 0) {
          this.startAudioPlayback();
        }
        onReady?.();
      } else if (err) {
        console.error(`Failed to initialize audio renderer: ${err.message}, code: ${err.code}`);
        this.info += `\n音频初始化失败: ${err.message}`;
      }
    });
  }

  startAudioPlayback() {
    if (!this.audioRenderer) {
      this.pendingPlaybackStart = true;
      this.initAudioRenderer();
      return;
    }
    this.pendingPlaybackStart = false;
    if (this.sampleBuffer.size() == 0) {
      return;
    }
    if (this.audioRenderer.state != audio.AudioState.STATE_RUNNING) {
      this.isPlaying = true;
      this.audioRenderer.start();
    }
  }

  stopAudioPlayback() {
    this.pendingPlaybackStart = false;
    this.isPlaying = false;
    this.audioRenderer?.stop();
  }

  aboutToAppear() {
    const workerOptions: TtsWorkerOptions = {
      name: 'NonStreaming TTS worker'
    };
    this.workerInstance = new worker.ThreadWorker(this.scriptURL, workerOptions);
    this.workerInstance.onmessage = (e: MessageEvents) => {
      const msgType = e.data['msgType'] as string;

      if (msgType == 'init-tts-done') {
        this.info = '模型初始化完成！\n请输入文字后点击「开始朗读」。';
        this.sampleRate = e.data['sampleRate'] as number;
        this.numSpeakers = e.data['numSpeakers'] as number;
        this.numThreads = e.data['numThreads'] as number;
        this.initTtsDone = true;
        this.initAudioRenderer();
      }

      if (msgType == 'tts-generate-partial') {
        if (this.cancelled) {
          return;
        }

        const samples: Float32Array = e.data['samples'] as Float32Array;
        const progress: number = e.data['progress'] as number;
        this.progress = progress;
        this.sampleBuffer.push(samples);
        this.startAudioPlayback();
      }

      if (msgType == 'tts-generate-done') {
        this.isGenerating = false;
        const samples: Float32Array = e.data['samples'] as Float32Array;

        systemTime.getRealTime((err, data) => {
          if (!err) {
            this.stopTime = data;
            const audioDuration = samples.length / this.sampleRate;
            const elapsedSeconds = (this.stopTime - this.startTime) / 1000;
            const RTF = elapsedSeconds / audioDuration;

            this.info = `音频时长: ${audioDuration.toFixed(2)} 秒
耗时: ${elapsedSeconds.toFixed(2)} 秒
RTF = ${elapsedSeconds.toFixed(2)}/${audioDuration.toFixed(2)} = ${RTF.toFixed(3)}
线程数: ${this.numThreads}
正在朗读...
`;
            if (this.cancelled) {
              this.info += '\n已取消。';
            }
          }
        });

        this.finalSamples = samples;
        this.btnSaveEnabled = true;

        if (this.cancelled) {
          this.ttsGeneratedDone = true;
          this.btnStartEnabled = true;
          this.btnStopEnabled = false;
          return;
        }

        if (this.sampleBuffer.size() == 0 && samples.length > 0) {
          this.sampleBuffer.push(samples);
          this.progress = 1;
          this.startAudioPlayback();
        }

        this.ttsGeneratedDone = true;
      }
    }

    this.info = '正在初始化 TTS 模型，请稍候...';
    const initMsg: InitTtsWorkerMessage = {
      msgType: 'init-tts',
      context: getContext(this)
    };
    this.workerInstance.postMessage(initMsg);
  }

  private audioPlayCallback = (buffer: ArrayBuffer) => {
    const numSamples = buffer.byteLength / 2;
    if (this.sampleBuffer.size() >= numSamples) {
      const samples: Float32Array = this.sampleBuffer.get(this.sampleBuffer.head(), numSamples);
      const int16Samples = new Int16Array(buffer);
      for (let i = 0; i < numSamples; ++i) {
        let s = samples[i] * 32767;
        s = s > 32767 ? 32767 : s;
        s = s < -32768 ? -32768 : s;
        int16Samples[i] = s;
      }
      this.sampleBuffer.pop(numSamples);
    } else {
      (new Int16Array(buffer)).fill(0);
      if (this.ttsGeneratedDone) {
        this.stopAudioPlayback();
        this.isPlaying = false;
        this.btnStartEnabled = true;
        this.btnStopEnabled = false;
        this.info += '\n朗读完成。';
      }
    }
  };

  build() {
    Column({ space: 10 }) {
      Text(this.title)
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 16, bottom: 8 })

      if (this.numSpeakers > 1) {
        Row({ space: 10 }) {
          Text(`说话人 ID (0-${this.numSpeakers - 1})`).width('60%')
          TextInput({ text: this.sid }).onChange((text) => {
            this.sid = text.trim();
          }).width('30%')
        }.width('100%').padding({ left: 16, right: 16 })
      }

      Row() {
        Text('语速').width('60%')
        TextInput({ text: this.speechSpeed }).onChange((text) => {
          this.speechSpeed = text.trim();
        }).width('30%')
      }.width('100%').padding({ left: 16, right: 16 })

      Row({ space: 10 }) {
        Button(this.btnStartCaption).enabled(this.btnStartEnabled).onClick(async () => {
          let sid = parseInt(this.sid);
          if (sid.toString() != this.sid) {
            this.info = '请输入有效的说话人 ID';
            return;
          }

          let speed = parseFloat(this.speechSpeed);
          if (isNaN(speed) || speed <= 0) {
            this.info = '请输入有效的语速（正数）';
            return;
          }

          if (this.workerInstance && this.initTtsDone) {
            this.cancelled = false;
            this.finalSamples = null;
            this.sampleBuffer.reset();
            this.ttsGeneratedDone = false;
            this.progress = 0;
            this.btnStartEnabled = false;
            this.btnStopEnabled = true;
            this.btnSaveEnabled = false;
            this.isGenerating = true;
            this.info = '正在合成并准备朗读...';
            this.startTime = await systemTime.getRealTime();
            const generateMsg: TtsGenerateWorkerMessage = {
              msgType: 'tts-generate',
              text: this.inputText,
              sid: sid,
              speed: speed,
            };
            this.workerInstance.postMessage(generateMsg);
          } else {
            this.info = 'TTS 模型尚未初始化完成';
            this.btnStartEnabled = false;
          }
        })

        Button(this.btnStopCaption).enabled(this.btnStopEnabled).onClick(() => {
          this.ttsGeneratedDone = true;
          this.btnStartEnabled = true;
          this.btnStopEnabled = false;
          this.sampleBuffer.reset();
          this.cancelled = true;
          this.isGenerating = false;
          const cancelMsg: TtsCancelWorkerMessage = {
            msgType: 'tts-generate-cancel'
          };
          this.workerInstance?.postMessage(cancelMsg);
          this.stopAudioPlayback();
        })

        Button(this.btnSaveCaption).enabled(this.btnSaveEnabled).onClick(() => {
          if (!this.finalSamples || this.finalSamples.length == 0) {
            this.btnSaveEnabled = false;
            return;
          }

          const audioOptions = new picker.AudioSaveOptions();
          const audioViewPicker = new picker.AudioViewPicker();
          audioViewPicker.save(audioOptions).then((audioSelectResult: Array<string>) => {
            const uri = audioSelectResult[0];
            if (this.finalSamples) {
              savePcmToWav(uri, toInt16Samples(this.finalSamples), this.sampleRate);
              this.info += `\n已保存至 ${uri}`;
            }
          });
        })
      }.width('100%').justifyContent(FlexAlign.Center)

      if (this.info != '') {
        TextArea({ text: this.info })
          .width('92%')
          .height(120)
          .focusable(false)
      }

      if (this.progress > 0) {
        Row() {
          Progress({ value: 0, total: 100, type: ProgressType.Capsule })
            .width('75%')
            .height(20)
            .value(this.progress * 100)
          Text(`${(this.progress * 100).toFixed(1)}%`).width('15%')
        }.width('100%').justifyContent(FlexAlign.Center)
      }

      TextArea({ placeholder: '请输入要朗读的文字，然后点击「开始朗读」' })
        .width('92%')
        .layoutWeight(1)
        .margin({ bottom: 16 })
        .focusable(this.isGenerating == false && this.initTtsDone)
        .onChange((text) => {
          this.inputText = text;
          this.btnStartEnabled = text.trim() != '' && this.initTtsDone;
        })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 8, right: 8 })
  }
}
