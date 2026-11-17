"""Office creation with bundled, pinned libraries. No macros or execution."""
import json, os, pathlib, uuid

def create_office(root, output, content):
    from core import safe_path
    target=safe_path(root,output)
    if target.exists(): raise ValueError('Файл уже существует: выбери новое имя')
    if not isinstance(content,dict) or len(json.dumps(content))>500000: raise ValueError('Некорректное или слишком большое содержимое')
    target.parent.mkdir(parents=True,exist_ok=True)
    tmp=target.with_name('.'+target.name+'.'+uuid.uuid4().hex)
    try:
        if target.suffix.lower()=='.docx':
            from docx import Document
            from docx.shared import Pt
            doc=Document(); doc.core_properties.author=''; doc.core_properties.last_modified_by=''; doc.core_properties.comments=''
            doc.styles['Normal'].font.name='Calibri'; doc.styles['Normal'].font.size=Pt(12)
            if content.get('title'): doc.add_heading(str(content['title']),0)
            for p in content.get('paragraphs',[]): doc.add_paragraph(str(p))
            for rows in content.get('tables',[]):
                if not rows: continue
                table=doc.add_table(rows=0,cols=max(len(r) for r in rows))
                for row in rows:
                    for cell,value in zip(table.add_row().cells,row): cell.text=str(value)
            doc.save(tmp)
        elif target.suffix.lower()=='.xlsx':
            import xlsxwriter
            wb=xlsxwriter.Workbook(str(tmp),{'strings_to_formulas':False,'strings_to_urls':False})
            wb.set_properties({'author':'','comments':''})
            try:
                for sheet in content.get('sheets') or [{'name':'Лист1','rows':[]}]:
                    ws=wb.add_worksheet(sheet.get('name','Лист1'))
                    for r,row in enumerate(sheet.get('rows',[])):
                        for c,value in enumerate(row):
                            if not isinstance(value,(str,int,float,bool,type(None))): raise ValueError('Ячейки: текст, число или логическое значение')
                            ws.write(r,c,value)
            finally: wb.close()
        elif target.suffix.lower()=='.pptx':
            from pptx import Presentation
            prs=Presentation(); prs.core_properties.author=''; prs.core_properties.last_modified_by=''; prs.core_properties.comments=''
            for item in content.get('slides') or [{'title':content.get('title',''),'body':''}]:
                slide=prs.slides.add_slide(prs.slide_layouts[1]); slide.shapes.title.text=str(item.get('title',''))
                body=item.get('body',''); slide.placeholders[1].text='\n'.join(map(str,body)) if isinstance(body,list) else str(body)
            prs.save(tmp)
        else: raise ValueError('Поддержаны DOCX, PPTX, XLSX')
        # Atomic exclusive publication, never overwrite an existing output.
        os.link(tmp,target)
    finally:
        if tmp.exists(): tmp.unlink()
    return {'written':str(target.relative_to(pathlib.Path(root).resolve())),'bytes':target.stat().st_size,'format':target.suffix[1:]}
