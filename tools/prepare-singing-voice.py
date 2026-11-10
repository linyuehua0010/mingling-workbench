"""将已有冥零音频或已保存的 Breeze 音色制作成 SoulX 参考，不设计新音色。"""
import argparse
import hashlib
import json
import re
import shutil
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


def make_metadata(audio, sample_rate, text, timestamps, phones, pitch_values, pitch_times):
    import numpy as np
    characters = re.findall(r'[\u4e00-\u9fff]', text)
    if len(characters) != len(timestamps) or len(characters) != len(phones):
        raise ValueError('字符数与对齐结果不一致，原参考未修改')
    frame_count = len(audio) // 480
    voiced = pitch_values[(pitch_values >= 65) & (pitch_values <= 800)]
    if len(voiced) < 3:
        raise ValueError('参考音频没有检测到足够人声，请更换清晰音频')
    fallback = float(np.median(voiced))
    segments = []
    cursor = 0
    for character, phone, interval in zip(characters, phones, timestamps):
        start = max(cursor, round(float(interval[0]) / 20))
        end = min(frame_count, round(float(interval[1]) / 20))
        if start >= frame_count or end <= start:
            raise ValueError('参考时间戳超出音频或时长不足，原参考未修改')
        if start > cursor:
            segments.append(('<SP>', '<SP>', start - cursor, 0, 1))
        frequencies = pitch_values[(pitch_times >= start * .02) & (pitch_times < end * .02)]
        frequencies = frequencies[(frequencies >= 65) & (frequencies <= 800)]
        frequency = float(np.median(frequencies)) if len(frequencies) else fallback
        midi = max(1, min(127, round(69 + 12 * np.log2(frequency / 440))))
        segments.append((character, phone, end - start, midi, 2))
        cursor = end
    if cursor < frame_count:
        segments.append(('<SP>', '<SP>', frame_count - cursor, 0, 1))
    return [{
        'index': 'mingling', 'language': 'Mandarin', 'time': [0, frame_count * 20],
        'text': ' '.join(row[0] for row in segments),
        'phoneme': ' '.join(row[1] for row in segments),
        'duration': ' '.join(f'{row[2] * .02:.3f}' for row in segments),
        'note_pitch': ' '.join(str(row[3]) for row in segments),
        'note_type': ' '.join(str(row[4]) for row in segments),
    }]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--base', required=True)
    parser.add_argument('--root', required=True)
    parser.add_argument('--from-breeze', action='store_true')
    args = parser.parse_args()
    base, root = Path(args.base).resolve(), Path(args.root).resolve()
    settings_path = base / 'private' / 'feature-settings.json'
    settings = json.loads(settings_path.read_text(encoding='utf-8-sig')).get('sing', {}) if settings_path.exists() else {}
    voice_id = settings.get('breeze_voice', 'mingling')
    breeze_url = settings.get('breeze_url', 'http://127.0.0.1:8137/v1').rstrip('/')
    service_url = settings.get('server_url', 'http://127.0.0.1:18620').rstrip('/')
    work = root / 'voice-build'
    work.mkdir(parents=True, exist_ok=True)
    source = base / 'pack' / 'mingling-pack' / 'voice' / 'mingling-参考.wav'
    transcript = (source.with_suffix('.txt')).read_text(encoding='utf-8-sig').strip()
    text = settings.get('breeze_text') or transcript
    if args.from_breeze:
        body = {'input': text, 'voice': voice_id, 'response_format': 'wav', 'seed': 42}
        request = urllib.request.Request(breeze_url + '/audio/speech', data=json.dumps(body, ensure_ascii=False).encode(),
                                         headers={'Content-Type': 'application/json'})
        print('正在使用已有 Breeze 音色生成参考，未创建新音色', flush=True)
        with urllib.request.urlopen(request, timeout=240) as response:
            content = response.read()
        if content[:4] != b'RIFF' or content[8:12] != b'WAVE':
            raise ValueError('Breeze 未返回有效 WAV，原参考未修改')
        source = work / 'breeze-mingling.wav'
        source.write_bytes(content)
    else:
        text = transcript
        voice_id = 'mingling'
    import librosa
    import numpy as np
    import parselmouth
    import soundfile as sf
    audio, sample_rate = sf.read(str(source), dtype='float32')
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if sample_rate != 24000:
        audio = librosa.resample(audio, orig_sr=sample_rate, target_sr=24000)
    if not 2 <= len(audio) / 24000 <= 30:
        raise ValueError('参考音频需为 2—30 秒，原参考未修改')
    wav = work / 'aligned-source.wav'
    sf.write(str(wav), audio, 24000, subtype='PCM_16')
    characters = re.findall(r'[\u4e00-\u9fff]', text)
    text_path = work / 'transcript.txt'
    # FunASR 的文本文件格式为「语句 ID + 文本」，否则首字会被当作 ID。
    text_path.write_text('mingling ' + ' '.join(characters) + '\n', encoding='utf-8')
    print('正在生成中文时间对齐和音高标注', flush=True)
    from modelscope.hub.snapshot_download import snapshot_download
    from funasr import AutoModel
    model_id = 'iic/speech_timestamp_prediction-v1-16k-offline'
    cache_dir = str(root / 'models' / 'alignment')
    try:
        alignment_model = snapshot_download(model_id, cache_dir=cache_dir, local_files_only=True)
    except Exception:
        alignment_model = snapshot_download(model_id, cache_dir=cache_dir)
    aligner = AutoModel(model=alignment_model, device='cpu', disable_update=True)
    aligned = aligner.generate(input=(str(wav), str(text_path)), data_type=('sound', 'text'))
    (work / 'alignment.json').write_text(json.dumps(aligned, ensure_ascii=False, indent=2), encoding='utf-8')
    timestamps = aligned[0].get('timestamp', []) if aligned else []
    sys.path.insert(0, str(root))
    import melodies
    phoneset_path = root / 'SoulX-Singer' / 'soulxsinger' / 'utils' / 'phoneme' / 'phone_set.json'
    phoneset = set(json.loads(phoneset_path.read_text(encoding='utf-8')))
    phones = melodies.to_phonemes(''.join(characters), phoneset)
    pitch = parselmouth.Sound(audio, sampling_frequency=24000).to_pitch(time_step=.01, pitch_floor=65, pitch_ceiling=800)
    metadata = make_metadata(audio, 24000, text, timestamps, phones, np.asarray(pitch.selected_array['frequency']), np.asarray(pitch.xs()))
    prepared = work / 'prompt.json'
    prepared.write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding='utf-8')
    # 先验证真实模型的数据处理器能读取新参考，成功后才替换。
    sys.path.insert(0, str(root / 'SoulX-Singer'))
    from soulxsinger.utils.data_processor import DataProcessor
    processor = DataProcessor(hop_size=480, sample_rate=24000, phoneset_path=str(phoneset_path), device='cpu')
    processor.process(dict(metadata[0]), str(wav))
    target = root / 'voice'
    backup = base / '旧版' / ('singing-voice-' + time.strftime('%Y%m%d-%H%M%S'))
    backup.mkdir(parents=True, exist_ok=True)
    target.mkdir(parents=True, exist_ok=True)
    for name in ('prompt.wav', 'prompt.json', 'reference.json'):
        if (target / name).exists():
            shutil.copy2(target / name, backup / name)
    shutil.copy2(wav, target / 'prompt.wav')
    shutil.copy2(prepared, target / 'prompt.json')
    reference = {'voice_id': voice_id, 'name': '冥零', 'source': 'breeze' if args.from_breeze else 'existing',
                 'alignment': 'FunASR-fa-zh', 'text': text, 'sha256': hashlib.sha256(wav.read_bytes()).hexdigest()}
    (target / 'reference.json').write_text(json.dumps(reference, ensure_ascii=False, indent=2), encoding='utf-8')
    try:
        request = urllib.request.Request(service_url + '/voice/reload', data=b'{}', headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=30) as response:
            result = json.loads(response.read().decode('utf-8'))
        if not result.get('ok'):
            raise ValueError('参考已保存，但服务尚未加载，请重启本地唱歌服务')
    except urllib.error.URLError as error:
        if isinstance(error, urllib.error.HTTPError):
            raise ValueError('冥零参考已保存，请更新并重启本地唱歌服务后使用') from error
        print('唱歌服务未运行；参考已保存，下次启动时生效', flush=True)
    print('RESULT ok=1 why=已应用现有冥零音色的唱歌参考', flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('RESULT ok=0 why=' + str(error), flush=True)
        sys.exit(1)
