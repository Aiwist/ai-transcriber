-- Bounded local metadata inspection only; no tensors, processes or network.
local M={}
function M.inspect(path,model)
  if type(path)~='string'or path==''then return 'модель не подключена'end
  local f=io.open(path,'rb');if not f then return 'файл модели недоступен'end
  local ok,result,bytes=pcall(function()
    local size=assert(f:seek('end'));f:seek('set',0)
    local consumed=0
    local function read(n)
      assert(n>=0 and consumed+n<=4194304,'слишком большой заголовок GGUF')
      local text=f:read(n);assert(text and #text==n,'GGUF обрезан');consumed=consumed+n;return text
    end
    local function number(fmt,n)return(string.unpack(fmt,read(n)))end
    local function string_value()local n=number('<I8',8);assert(n<=1048576,'слишком длинная строка GGUF');return read(n)end
    local formats={[0]={'<I1',1},[1]={'<i1',1},[2]={'<I2',2},[3]={'<i2',2},[4]={'<I4',4},[5]={'<i4',4},[6]={'<f',4},[7]={'<I1',1},[10]={'<I8',8},[11]={'<i8',8},[12]={'<d',8}}
    local value
    value=function(kind,depth)
      assert(depth<4,'вложенные массивы GGUF слишком глубоки')
      if kind==8 then return string_value()end
      if kind==9 then
        local subtype,count=number('<I4',4),number('<I8',8);assert(count<=65536,'слишком большой массив GGUF')
        for _=1,count do value(subtype,depth+1)end;return nil
      end
      local fmt=assert(formats[kind],'неизвестный тип GGUF');return number(fmt[1],fmt[2])
    end
    assert(read(4)=='GGUF','выбран не GGUF-файл')
    assert(number('<I4',4)==3,'неподдерживаемая версия GGUF')
    local tensors,fields=number('<I8',8),number('<I8',8)
    assert(tensors>0 and tensors<=10000 and fields<=4096,'повреждён заголовок GGUF')
    local meta={}
    for _=1,fields do local key=string_value();meta[key]=value(number('<I4',4),0)end
    assert(meta['general.architecture']=='muscriptor'and meta['muscriptor.format_version']==1,'нужна модель GGUF для muscriptor.cpp (как в NeuralNote)')
    local label=({small='103M',medium='307M',large='1.4B'})[model]
    if label and meta['general.size_label']then assert(meta['general.size_label']==label,'размер GGUF не соответствует выбранной модели '..model)end
    local expected_layers=({small=14,medium=24,large=48})[model]
    if expected_layers then assert(meta['muscriptor.block_count']==expected_layers,'архитектура не соответствует '..model)end
    local max_end=0
    for _=1,tensors do
      string_value();local dimensions=number('<I4',4);assert(dimensions>=1 and dimensions<=4,'неверные размеры тензора')
      local elements=1;for _=1,dimensions do local n=number('<I8',8);assert(n>0 and n<10000000,'повреждены размеры тензора');elements=elements*n;assert(elements<10000000000,'слишком большой тензор')end
      local kind,offset=number('<I4',4),number('<I8',8);assert(kind==0 or kind==1,'эта версия поддерживает F32/F16 GGUF')
      max_end=math.max(max_end,offset+elements*(kind==0 and 4 or 2))
    end
    local align=meta['general.alignment']or 32;assert(type(align)=='number'and align>=1 and align<=4096,'неверное выравнивание GGUF')
    local data_start=math.ceil(consumed/align)*align
    local data_end=data_start+max_end
    assert(data_end==size,'размер GGUF не совпадает с заголовком: файл повреждён или обрезан')
    return nil,size
  end)
  f:close();if not ok then local message=tostring(result):gsub('^.-:%d+: ','');return message end;return result,bytes
end
return M
