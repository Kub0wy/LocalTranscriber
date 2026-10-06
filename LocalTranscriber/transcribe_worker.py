import argparse, json
import mlx_whisper

p = argparse.ArgumentParser()
p.add_argument('--input', required=True)
p.add_argument('--output', required=True)
p.add_argument('--model', required=True)
p.add_argument('--language', default='auto')
p.add_argument('--task', choices=['transcribe', 'translate'], default='transcribe')
p.add_argument('--config', required=True)
a = p.parse_args()

with open(a.config, 'r', encoding='utf-8') as f:
    options = json.load(f)
if not isinstance(options, dict):
    raise ValueError('Transcription config must be a JSON object')

# Core values are controlled by the GUI, not the advanced JSON field.
for reserved in ('path_or_hf_repo', 'language', 'task'):
    options.pop(reserved, None)

kwargs = dict(options)
kwargs['path_or_hf_repo'] = a.model
kwargs['task'] = a.task
kwargs['verbose'] = True
if a.language != 'auto':
    kwargs['language'] = a.language

result = mlx_whisper.transcribe(a.input, **kwargs)
out = {
    'text': result.get('text', ''),
    'segments': [
        {'start': float(s['start']), 'end': float(s['end']), 'text': s.get('text','')}
        for s in result.get('segments', [])
    ]
}
with open(a.output, 'w', encoding='utf-8') as f:
    json.dump(out, f, ensure_ascii=False)
