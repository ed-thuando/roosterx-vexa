import { Page } from 'playwright';
import { BotConfig } from '../../../types';
import { RecordingService } from '../../../services/recording';
import { getRawCaptureService } from '../../../index';
import { log } from '../../../utils';
import { PulseAudioCapture, UnifiedRecordingPipeline } from '../../../services/audio-pipeline';
import { zoomParticipantNameSelector, zoomVideoAvatarSelector } from './selectors';
import { dismissZoomPopups } from './prepare';
import { startZoomRichObservation } from './observe';

let recordingService: RecordingService | null = null;
let recordingStopResolver: (() => void) | null = null;
let recordingRejecter: ((err: Error) => void) | null = null;
let pipeline: UnifiedRecordingPipeline | null = null;
let speakerPollInterval: NodeJS.Timeout | null = null;
let autoLeaveInterval: NodeJS.Timeout | null = null;
let lastActiveSpeaker: string | null = null;
let popupDismissInterval: NodeJS.Timeout | null = null;
/** Q1=A silence clock — Node-side (Zoom uses PulseAudio, not browser RMS). */
let lastAudioActivityTs = 0;

/** Current DOM-polled active speaker — used by per-speaker pipeline as fallback name */
export function getLastActiveSpeaker(): string | null {
  return lastActiveSpeaker;
}

function pcmWavHasEnergy(data: Buffer, threshold = 200): boolean {
  // Skip 44-byte RIFF header; samples are s16le mono/stereo.
  const start = data.length > 44 ? 44 : 0;
  for (let i = start; i + 1 < data.length; i += 32) {
    const sample = Math.abs(data.readInt16LE(i));
    if (sample > threshold) return true;
  }
  return false;
}

function clearAutoLeaveMonitor(): void {
  if (autoLeaveInterval) {
    clearInterval(autoLeaveInterval);
    autoLeaveInterval = null;
  }
}

function startAutoLeaveMonitoring(page: Page, botConfig: BotConfig): void {
  const leaveCfg = botConfig.automaticLeave || ({} as BotConfig["automaticLeave"]);
  const startupAloneTimeoutSeconds = Math.floor(Number(leaveCfg.noOneJoinedTimeout || 600000) / 1000);
  const everyoneLeftTimeoutSeconds = Math.floor(Number(leaveCfg.everyoneLeftTimeout || 600000) / 1000);
  const silenceTimeoutSeconds = Math.floor(
    Number(leaveCfg.noAudioActivityTimeout ?? 600000) / 1000,
  );

  // Q1=A: arm silence clock when monitoring starts.
  lastAudioActivityTs = Date.now();

  let aloneTime = 0;
  let speakersIdentified = false;

  autoLeaveInterval = setInterval(async () => {
    if (!page || page.isClosed()) return;
    try {
      // R1 — silence / inactive
      if (silenceTimeoutSeconds > 0) {
        const silenceElapsedSec = Math.floor((Date.now() - lastAudioActivityTs) / 1000);
        if (silenceElapsedSec >= silenceTimeoutSeconds) {
          log(
            `[Zoom Web] inactive: no audio activity for ${silenceElapsedSec}s (limit ${silenceTimeoutSeconds}s). Leaving...`,
          );
          clearAutoLeaveMonitor();
          if (recordingRejecter) {
            recordingRejecter(new Error("ZOOM_BOT_INACTIVE_NO_AUDIO_TIMEOUT"));
            recordingRejecter = null;
            recordingStopResolver = null;
          }
          return;
        }
      }

      // R2 — alone / everyone left (DOM tile count excludes bot-only ≈ ≤1)
      const participantCount = await page.evaluate((avatarSelector: string) => {
        return document.querySelectorAll(avatarSelector).length;
      }, zoomVideoAvatarSelector);

      if (participantCount > 1) {
        speakersIdentified = true;
        aloneTime = 0;
        return;
      }

      aloneTime++;
      const currentTimeout = speakersIdentified
        ? everyoneLeftTimeoutSeconds
        : startupAloneTimeoutSeconds;
      if (aloneTime >= currentTimeout) {
        const err = speakersIdentified
          ? new Error("ZOOM_BOT_LEFT_ALONE_TIMEOUT")
          : new Error("ZOOM_BOT_STARTUP_ALONE_TIMEOUT");
        log(
          `[Zoom Web] alone for ${aloneTime}s (limit ${currentTimeout}s, speakersIdentified=${speakersIdentified}). Leaving...`,
        );
        clearAutoLeaveMonitor();
        if (recordingRejecter) {
          recordingRejecter(err);
          recordingRejecter = null;
          recordingStopResolver = null;
        }
      }
    } catch {
      // Page navigating — ignore tick
    }
  }, 1000);
}

export async function startZoomWebRecording(page: Page | null, botConfig: BotConfig): Promise<void> {
  if (!page) throw new Error('[Zoom Web] Page required for recording');

  const wantsAudioCapture =
    !!botConfig.recordingEnabled &&
    (!Array.isArray(botConfig.captureModes) || botConfig.captureModes.includes('audio'));
  const sessionUid = botConfig.connectionId || `zoom-web-${Date.now()}`;

  if (wantsAudioCapture) {
    if (!botConfig.recordingUploadUrl || !botConfig.token) {
      log('[Zoom Web] recordingUploadUrl or token missing — skipping audio capture');
    } else {
      recordingService = new RecordingService(botConfig.meeting_id, sessionUid);
      const source = new PulseAudioCapture();

      // Feed silence / inactive detector from PCM energy on each chunk.
      source.on("chunk", (chunk) => {
        if (chunk?.data && pcmWavHasEnergy(chunk.data)) {
          lastAudioActivityTs = Date.now();
        }
      });

      pipeline = new UnifiedRecordingPipeline({
        source,
        recordingService,
        uploadUrl: botConfig.recordingUploadUrl,
        token: botConfig.token,
        platform: 'zoom-web',
      });
      await pipeline.start();
      log('[Zoom Web] Unified recording pipeline started (PulseAudio → chunked upload)');
    }
  }

  // Start speaker detection polling via DOM
  startSpeakerPolling(page, botConfig);

  // Periodically dismiss popups (AI Companion, chat guest tooltip, etc.)
  popupDismissInterval = setInterval(() => {
    dismissZoomPopups(page).catch(() => {});
  }, 2000);

  if (process.env.ZOOM_OBSERVE === 'true') {
    try {
      await startZoomRichObservation(page);
    } catch (e: any) {
      log(`[Zoom Web] ZOOM_OBSERVE harness failed to install: ${e.message}`);
    }
  }

  startAutoLeaveMonitoring(page, botConfig);

  // Block until stopZoomWebRecording() or auto-leave reject
  await new Promise<void>((resolve, reject) => {
    recordingStopResolver = resolve;
    recordingRejecter = reject;
  });
}

export async function stopZoomWebRecording(): Promise<void> {
  log('[Zoom Web] Stopping recording');

  clearAutoLeaveMonitor();

  if (speakerPollInterval) {
    clearInterval(speakerPollInterval);
    speakerPollInterval = null;
  }

  if (popupDismissInterval) {
    clearInterval(popupDismissInterval);
    popupDismissInterval = null;
  }

  lastActiveSpeaker = null;

  if (recordingStopResolver) {
    recordingStopResolver();
    recordingStopResolver = null;
  }
  recordingRejecter = null;

  if (pipeline) {
    await pipeline.stop();
    pipeline = null;
  }

  recordingService = null;
}

export async function reconfigureZoomWebRecording(language: string | null, task: string | null): Promise<void> {
  log(`[Zoom Web] reconfigure: ignoring (lang=${language}, task=${task})`);
}

export function getZoomWebRecordingService(): RecordingService | null {
  return recordingService;
}

// ---- Speaker detection via DOM polling ----

function startSpeakerPolling(page: Page, botConfig: BotConfig): void {
  speakerPollInterval = setInterval(async () => {
    if (!page || page.isClosed()) return;
    try {
      const speakerName = await page.evaluate((footerSelector: string) => {
        function nameFromContainer(container: Element | null): string | null {
          if (!container) return null;
          const footer = container.querySelector(footerSelector);
          if (!footer) return null;
          const span = footer.querySelector('span');
          return (span?.textContent?.trim() || (footer as HTMLElement).innerText?.trim()) || null;
        }

        const name1 = nameFromContainer(document.querySelector('.speaker-active-container__video-frame'));
        if (name1) return name1;

        const name2 = nameFromContainer(document.querySelector('.speaker-bar-container__video-frame--active'));
        if (name2) return name2;

        return null;
      }, zoomParticipantNameSelector);

      if (speakerName && speakerName !== lastActiveSpeaker) {
        const rawCapture = getRawCaptureService();
        if (rawCapture) {
          rawCapture.logSpeakerEvent(lastActiveSpeaker, speakerName);
        }
        if (lastActiveSpeaker) {
          log(`🔇 [Zoom Web] SPEAKER_END: ${lastActiveSpeaker}`);
        }
        lastActiveSpeaker = speakerName;
        log(`🎤 [Zoom Web] SPEAKER_START: ${speakerName}`);
        // Active speaker UI implies acoustic activity for silence timer.
        lastAudioActivityTs = Date.now();
      } else if (!speakerName && lastActiveSpeaker) {
        log(`🔇 [Zoom Web] SPEAKER_END: ${lastActiveSpeaker}`);
        lastActiveSpeaker = null;
      }
    } catch {
      // Page may be navigating — ignore
    }
  }, 250);
}
