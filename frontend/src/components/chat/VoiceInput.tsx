import { useState, useRef, useCallback, useEffect } from 'react';
import { Button, Toast, ToastTitle, Toaster, useId, useToastController } from '@fluentui/react-components';
import { MicRegular, MicOffRegular } from '@fluentui/react-icons';
import styles from './VoiceInput.module.css';

interface VoiceInputProps {
  onTranscript: (text: string) => void;
  disabled?: boolean;
}

export const VoiceInput: React.FC<VoiceInputProps> = ({ onTranscript, disabled = false }) => {
  const [isListening, setIsListening] = useState(false);
  const recognitionRef = useRef<SpeechRecognition | null>(null);

  useEffect(() => {
    return () => {
      recognitionRef.current?.abort();
    };
  }, []);

  const toasterId = useId('voice-toaster');
  const { dispatchToast } = useToastController(toasterId);

  const toggleListening = useCallback(() => {
    const SpeechRecognitionCtor = window.SpeechRecognition || window.webkitSpeechRecognition;

    if (!SpeechRecognitionCtor) {
      dispatchToast(
        <Toast>
          <ToastTitle>Voice input not supported in this browser</ToastTitle>
        </Toast>,
        { intent: 'warning' },
      );
      return;
    }

    if (recognitionRef.current) {
      recognitionRef.current.abort();
      recognitionRef.current = null;
      setIsListening(false);
      return;
    }

    const recognition = new SpeechRecognitionCtor();
    recognition.continuous = false;
    recognition.interimResults = false;
    recognition.lang = 'en-US';

    recognition.onresult = (event: SpeechRecognitionEvent) => {
      const transcript = event.results?.[0]?.[0]?.transcript;
      if (transcript) onTranscript(transcript);
    };

    recognition.onend = () => {
      recognitionRef.current = null;
      setIsListening(false);
    };

    recognition.onerror = (event: SpeechRecognitionErrorEvent) => {
      recognitionRef.current = null;
      setIsListening(false);

      const msg =
        event.error === 'not-allowed'          ? 'Microphone access denied. Check browser permissions.' :
        event.error === 'no-speech'            ? 'No speech detected. Please try again.' :
        event.error === 'network'              ? 'Network error during voice input. Speech recognition requires access to Google\'s speech servers.' :
        event.error === 'audio-capture'        ? 'Microphone not found or unavailable.' :
        event.error === 'service-not-allowed'  ? 'Speech recognition service is not allowed. Ensure the site is served over HTTPS.' :
        event.error === 'language-not-supported' ? 'Language not supported for speech recognition.' :
        event.error === 'aborted'              ? null :
        `Speech recognition error: ${event.error}`;

      if (msg) {
        dispatchToast(
          <Toast><ToastTitle>{msg}</ToastTitle></Toast>,
          { intent: 'error' },
        );
      }
    };

    recognitionRef.current = recognition;
    try {
      recognition.start();
    } catch (err) {
      recognitionRef.current = null;
      dispatchToast(
        <Toast><ToastTitle>Failed to start voice input. Please try again.</ToastTitle></Toast>,
        { intent: 'error' },
      );
      return;
    }
    setIsListening(true);
  }, [onTranscript, dispatchToast]);

  return (
    <>
      <Toaster toasterId={toasterId} position="top-end" />
      <Button
        appearance="subtle"
        icon={isListening ? <MicOffRegular /> : <MicRegular />}
        onClick={toggleListening}
        disabled={disabled}
        aria-label={isListening ? 'Stop voice input' : 'Start voice input'}
        aria-pressed={isListening}
        className={`${styles.voiceButton} ${isListening ? styles.listening : ''}`}
      >
        {isListening && <span className={styles.pulsingDot} />}
      </Button>
    </>
  );
};
