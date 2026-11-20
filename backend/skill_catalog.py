"""Bounded discovery inside user-selected roots; imports never execute code."""
import os, pathlib, re, shutil

def discover(root):
    root=pathlib.Path(root).resolve(); found=[]
    for folder,dirs,files in os.walk(root,followlinks=False):
        base=pathlib.Path(folder); depth=len(base.relative_to(root).parts)
        dirs[:]=sorted(d for d in dirs if not (base/d).is_symlink()) if depth<3 else []
        if 'SKILL.md' in files and not (base/'SKILL.md').is_symlink(): found.append(base/'SKILL.md')
        if len(found)>100: raise ValueError('Skill catalog exceeds 100 packages')
    return found

def refresh(store,pid,root=None):
    from core import parse_skill,uid
    project=store.project(pid)
    roots=project.setdefault('skillRoots',[])
    if root is not None:
        path=pathlib.Path(root).expanduser().resolve()
        if not path.is_dir():raise ValueError('Select a skill folder or its parent folder')
        if str(path) not in roots:roots.append(str(path))
    imported=[]
    for base in roots:
        for source in discover(base):
            if source.stat().st_size>200000:continue
            if str(source) in project.get('ignoredSkills',[]):continue
            existing=next((s for s in project['skills'] if s.get('source')==str(source)),None)
            stamp=source.stat().st_mtime_ns
            if existing and existing.get('sourceStamp')==stamp:continue
            members=list(source.parent.rglob('*'))
            if any(p.is_symlink() for p in members):continue
            files=[p for p in members if p.is_file()]
            if len(files)>300 or sum(p.stat().st_size for p in files)>20*1024*1024:continue
            skill=parse_skill(source.read_text(encoding='utf-8'),source.parent.name)
            skill_id=existing['id'] if existing else uid()
            target=store.root/'projects'/pid/'skills'/skill_id
            if target.exists():
                archive=store.root/'projects'/pid/'skill-archives'/uid(); archive.parent.mkdir(parents=True,exist_ok=True); target.rename(archive)
            shutil.copytree(source.parent,target)
            skill.update(id=skill_id,folder=str(target),source=str(source),sourceStamp=stamp)
            if existing:project['skills'].remove(existing)
            project['skills'].append(skill);imported.append(skill_id)
    store.save();return imported

def activated(project,chat):
    # Match explicit frontmatter triggers, or words from the name. Description is
    # not treated as arbitrary instructions. Activation never grants tool rights.
    last=next((m.get('content','') for m in reversed(chat['messages']) if m['role']=='user'),'').casefold()
    out=[]
    for skill in project['skills']:
        triggers=skill.get('triggers') or re.findall(r'[\w-]{3,}',skill['name'].casefold())
        if skill['id'] in chat['skillIDs'] or any(re.search(r'(?<!\w)'+re.escape(t.casefold())+r'(?!\w)',last) for t in triggers):out.append(skill)
    return out
