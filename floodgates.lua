-- FLOODGATES
-- 7-voice Arpeggiated Granular Synth
-- by @nzimas

engine.name = "Glut"
local MusicUtil = require "musicutil"

-------------------------
-- GLOBAL LOCK & CROSSFADE
-------------------------
local loading_lock = false
local CROSSFADE_MS = 30

-------------------------
-- CONSTANTS
-------------------------
local NUM_VOICES  = 7
local SQUARE_SIZE = 20

-- If you want to add or reorder these fractions, you can do so
local RATE_OPTIONS = {
  "16/1","8/1","4/1","2/1","1","1/2","1/4","1/8","1/16"
}

local SCALE_NAMES = { "Dorian","Natural Minor","Harmonic Minor","Blues","Major" }
local SCALE_INTERVALS = {
  ["Dorian"]         = {0,2,3,5,7,9,10},
  ["Natural Minor"]  = {0,2,3,5,7,8,10},
  ["Harmonic Minor"] = {0,2,3,5,7,8,11},
  ["Blues"]          = {0,3,5,6,7,10},
  ["Major"]          = {0,2,4,5,7,9,11},
}
local NOTE_NAMES = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}

-- For drawing squares
local positions = {
  {x=10,y=10},   -- voice 1
  {x=40,y=10},
  {x=70,y=10},
  {x=100,y=10},
  {x=25,y=40},
  {x=55,y=40},
  {x=85,y=40},
}

-------------------------
-- VOICE STATE
-------------------------
local voices = {}
for i=1, NUM_VOICES do
  voices[i] = {
    active            = false,
    midi_note         = nil,
    arp_clock         = nil,
    notes_held        = {},
    chord_tones       = {},

    -- For locking an arpeggio shape
    locked_chord      = {},
    locked_dir        = nil,
    locked_root       = nil,
    -- durations array is no longer stored; we re-check "rate" param each chord tone
  }
end

local random_seek_metros = {}

-------------------------
-- RANDOM HELPERS
-------------------------
local function random_float(low,high)
  return low + math.random()*(high - low)
end
local function random_int(low,high)
  return math.floor(random_float(low, high+1))
end

-------------------------
-- SAMPLE DIRECTORY
-------------------------
local sample_dir = _path.audio

local function file_dir_name(fp)
  return string.match(fp,"^(.*)/[^/]*$") or fp
end

local function pick_random_file(dir)
  if not dir or dir=="" then return "" end
  local files = util.scandir(dir)
  if not files then return "" end
  local audio_files={}
  for _,f in ipairs(files) do
    local lf= f:lower()
    if lf:match("%.wav$")
       or lf:match("%.aif$")
       or lf:match("%.aiff$")
       or lf:match("%.flac$") then
      table.insert(audio_files, dir.."/"..f)
    end
  end
  if #audio_files>0 then
    return audio_files[ math.random(#audio_files) ]
  else
    return ""
  end
end

-------------------------
-- SCALE & CHORD
-------------------------
local function build_scale_notes()
  local root_index= params:get("key") - 1
  local root_midi = 60 + root_index
  local scale_name= SCALE_NAMES[ params:get("scale") ]
  local intervals = SCALE_INTERVALS[scale_name]
  local notes={}
  for octave=-1,6 do
    local base= root_midi + 12*octave
    for _,iv in ipairs(intervals) do
      table.insert(notes, base+iv)
    end
  end
  table.sort(notes)
  return notes
end

local function generate_chord(voice_idx, triggered_note)
  local num_notes= params:get(voice_idx.."num_notes")
  local spread   = params:get(voice_idx.."arp_spread")
  local scale_notes= build_scale_notes()
  local chord_tones= {triggered_note}

  local valid_tones={}
  for _,n in ipairs(scale_notes) do
    local diff= n - triggered_note
    if diff>=-(spread*12) and diff<=(spread*12) then
      table.insert(valid_tones,n)
    end
  end
  table.sort(valid_tones)

  local pruned={}
  for _,v in ipairs(valid_tones) do
    if v~=triggered_note then
      table.insert(pruned,v)
    end
  end
  for _=1,(num_notes-1) do
    if #pruned<1 then break end
    local idx= random_int(1,#pruned)
    table.insert(chord_tones, pruned[idx])
    table.remove(pruned, idx)
  end
  table.sort(chord_tones)
  return chord_tones
end

-------------------------
-- SCALE-BASED TRANSPOSITION
-------------------------
local function note_index_in_scale(note, scale_array)
  for idx,v in ipairs(scale_array) do
    if v== note then
      return idx
    end
  end
  return nil
end

local function scale_transpose(locked_chord, locked_root, new_note)
  local scale_array= build_scale_notes()
  local old_root_idx= note_index_in_scale(locked_root, scale_array)
  local new_root_idx= note_index_in_scale(new_note, scale_array)

  if not old_root_idx or not new_root_idx then
    -- fallback semitone shift
    local semis= new_note- locked_root
    local result={}
    for _,c in ipairs(locked_chord) do
      table.insert(result, c+semis)
    end
    return result
  end

  local deg_diff= new_root_idx - old_root_idx
  local transposed={}

  for _,c in ipairs(locked_chord) do
    local old_idx= note_index_in_scale(c, scale_array)
    if old_idx then
      local new_idx= old_idx + deg_diff
      if new_idx<1 then new_idx=1 end
      if new_idx>#scale_array then new_idx=#scale_array end
      table.insert(transposed, scale_array[new_idx])
    else
      -- fallback semitone shift
      local semis= new_note - locked_root
      table.insert(transposed, c+semis)
    end
  end
  return transposed
end

-------------------------
-- GRAIN RANDOMIZER
-------------------------
local function smooth_transition(param_name,new_val,duration)
  clock.run(function()
    local start_val= params:get(param_name)
    local steps= 20
    local dt= duration/steps
    for s=1, steps do
      local t= s/steps
      params:set(param_name, start_val+(new_val-start_val)*t)
      clock.sleep(dt)
    end
    params:set(param_name, new_val)
  end)
end

local function randomize_voice_grains(i)
  local morph= params:get("morph_time") /1000
  local s_size= random_float(params:get("grain_min_size"),    params:get("grain_max_size"))
  local s_dens= random_float(params:get("grain_min_density"), params:get("grain_max_density"))
  local s_sprd= random_float(params:get("grain_min_spread"),  params:get("grain_max_spread"))
  local s_jitt= random_float(params:get("grain_min_jitter"),  params:get("grain_max_jitter"))

  smooth_transition(i.."size",    s_size, morph)
  smooth_transition(i.."density", s_dens,morph)
  smooth_transition(i.."spread",  s_sprd,morph)
  smooth_transition(i.."jitter",  s_jitt,morph)
end

local function randomize_all_grains()
  for i=1, NUM_VOICES do
    randomize_voice_grains(i)
  end
end

-------------------------
-- RANDOM SEEK
-------------------------
local function random_seek_tick(voice_idx)
  engine.seek(voice_idx, math.random())
  local tmin= params:get(voice_idx.."rnd_seek_min")
  local tmax= params:get(voice_idx.."rnd_seek_max")
  if tmax<tmin then
    local tmp= tmin
    tmin= tmax
    tmax= tmp
  end
  local next_s= math.random(tmin,tmax)/1000
  random_seek_metros[voice_idx].time= next_s
  random_seek_metros[voice_idx]:start()
end

local function update_random_seek(i)
  if params:get(i.."rnd_seek")==2 then
    if not random_seek_metros[i] then
      random_seek_metros[i]= metro.init()
      random_seek_metros[i].event= function()
        random_seek_tick(i)
      end
    end
    random_seek_tick(i)
  else
    if random_seek_metros[i] then
      random_seek_metros[i]:stop()
    end
  end
end

-------------------------
-- CONCURRENCY LOCK + CROSSFADE
-------------------------
local function safe_sample_load(voice_idx, path)
  if path=="" then return end

  clock.run(function()
    while loading_lock do
      clock.sleep(0.01)
    end
    loading_lock= true

    local user_db= params:get(voice_idx.."volume")
    local steps=15
    local fade_s= CROSSFADE_MS/1000
    local step_s= fade_s/steps

    -- fade out
    local start_db= user_db
    local end_db  = -60
    for s=1, steps do
      local t= s/steps
      local cur_db= start_db+(end_db-start_db)*t
      engine.volume(voice_idx, math.pow(10,cur_db/20))
      clock.sleep(step_s)
    end
    engine.volume(voice_idx, math.pow(10,-60/20))

    engine.read(voice_idx, path)

    -- fade in
    for s=1, steps do
      local t= s/steps
      local cur_db= end_db+(start_db-end_db)*t
      engine.volume(voice_idx, math.pow(10,cur_db/20))
      clock.sleep(step_s)
    end
    engine.volume(voice_idx, math.pow(10,user_db/20))

    loading_lock= false
  end)
end

-------------------------
-- ARPEGGIO LOOP
-------------------------
local function pick_random_direction()
  local r= random_int(1,4)
  if r==1 then return "up"
  elseif r==2 then return "down"
  elseif r==3 then return "pingpong"
  else return "random"
  end
end

-- We'll re-check the rate param for each chord tone so user sees real-time changes
local function fraction_to_beats(str)
  local num, den= string.match(str,"^(%d+)%/(%d+)$")
  if num and den then
    return tonumber(num)/tonumber(den)
  elseif str=="1" then
    return 1
  end
  return 1
end

local function run_arpeggio(voice_idx)
  local v= voices[voice_idx]
  v.active = true
  local chord= v.chord_tones
  local csize= #chord
  if csize<1 then
    engine.gate(voice_idx,0)
    return
  end

  local locked= (params:get(voice_idx.."lock_arpeggio")==2)
  local direction
  if locked then
    direction= v.locked_dir
  else
    direction= pick_random_direction()
    v.locked_chord = chord
    v.locked_dir   = direction
    v.locked_root  = v.midi_note
  end

  engine.gate(voice_idx,1)

  local base_path= params:get(voice_idx.."base_sample")
  local do_rand  = (params:get(voice_idx.."rnd_sample")==2)

  local is_first= true
  local i=1
  local dirsign=1

  while v.active do
    local note
    if direction=="random" then
      note = chord[ random_int(1, csize) ]
    else
      note = chord[i]
    end

    -- Ensure the UI updates whenever a new note plays
    local was_active = v.active
v.active = true
if not was_active then
  redraw()  -- Call redraw() only when `active` status actually changes
end

    -- load sample
    if is_first then
      if base_path~="" then
        safe_sample_load(voice_idx, base_path)
      end
      is_first=false
    else
      if do_rand then
        local path= pick_random_file(sample_dir)
        if path~="" then
          safe_sample_load(voice_idx, path)
        end
      else
        if base_path~="" then
          safe_sample_load(voice_idx, base_path)
        end
      end
    end

    -- random grains?
    if params:get(voice_idx.."rnd_grains")==2 then
      randomize_voice_grains(voice_idx)
    end

    -- set pitch
    local ratio= math.pow(2,(note-60)/12)
    engine.pitch(voice_idx, ratio)

    -- random velocity?
    if params:get(voice_idx.."rnd_velocity")==2 then
      local vmin= params:get(voice_idx.."min_rnd_vel")
      local vmax= params:get(voice_idx.."max_rnd_vel")
      local rv= random_float(vmin,vmax)
      engine.volume(voice_idx, math.pow(10, rv/20))
    else
      local vol_db= params:get(voice_idx.."volume")
      engine.volume(voice_idx, math.pow(10, vol_db/20))
    end

    -- NOW the key difference: Re-check the Rate param each chord tone
    local rate_str= RATE_OPTIONS[ params:get(voice_idx.."rate") ]
    local base_beat= fraction_to_beats(rate_str)
    -- add a random factor
    local factor= random_float(0.7,1.3)
    local step_beats= factor * base_beat
    clock.sleep(step_beats* clock.get_beat_sec())

    -- direction stepping
    if direction=="up" then
      i= i+1
      if i>csize then i=1 end
    elseif direction=="down" then
      i= i-1
      if i<1 then i=csize end
    elseif direction=="pingpong" then
      i= i+ dirsign
      if i>csize then
        i= csize-1
        dirsign= -1
      elseif i<1 then
        i= 2
        dirsign= 1
      end
    end
  end

  engine.gate(voice_idx,0)
end

-------------------------
-- MIDI
-------------------------
local midi_in

local function midi_event(data)
  local msg= midi.to_msg(data)
  if msg.type=="note_on" then
    if msg.vel>0 then
      for i=1, NUM_VOICES do
        if params:get(i.."midi_channel") == msg.ch and
   msg.note >= params:get(i.."midi_note_min") and
   msg.note <= params:get(i.."midi_note_max") then
          local v= voices[i]
          if not v.active then
          v.active = true
          redraw()  -- Force screen update when a voice is activated
           end
          local locked= (params:get(i.."lock_arpeggio")==2)

          if locked then
            -- re-trigger last shape, transposed
            if v.arp_clock then
              clock.cancel(v.arp_clock)
              v.arp_clock= nil
            end
            v.active= true
            v.notes_held[msg.note]= true

            -- If there's a locked chord+root, transpose it
            if #v.locked_chord>0 and v.locked_root then
              local transposed= scale_transpose(v.locked_chord, v.locked_root, msg.note)
              v.chord_tones= transposed
            else
              v.chord_tones= {}
            end

            v.arp_clock= clock.run(function()
              run_arpeggio(i)
            end)
          else
            -- normal chord generation
            if v.arp_clock then
              clock.cancel(v.arp_clock)
              v.arp_clock= nil
            end
            v.active= true
            v.midi_note= msg.note
            v.notes_held[msg.note]= true

            local chord= generate_chord(i, msg.note)
            v.chord_tones= chord

            v.arp_clock= clock.run(function()
              run_arpeggio(i)
            end)
          end
        end
      end
    else
      -- velocity=0 => note_off
      for i=1, NUM_VOICES do
        if params:get(i.."midi_channel") == msg.ch and
     msg.note >= params:get(i.."midi_note_min") and
     msg.note <= params:get(i.."midi_note_max") then
          local v= voices[i]
          if not v.active then
        v.active = true
        redraw()  -- Force screen update when a voice is activated
           end
          v.notes_held[msg.note]= nil
          local count=0
          for _,val in pairs(v.notes_held) do
            if val then count= count+1 end
          end
          if count==0 then
            v.active= false
          end
        end
      end
    end
  elseif msg.type=="note_off" then
    for i=1, NUM_VOICES do
       if params:get(i.."midi_channel") == msg.ch and
     msg.note >= params:get(i.."midi_note_min") and
     msg.note <= params:get(i.."midi_note_max") then
        local v= voices[i]
        v.notes_held[msg.note]= nil
        local count=0
        for _,val in pairs(v.notes_held) do
          if val then count= count+1 end
        end
        if count==0 then
          v.active= false
           redraw()
        end
      end
    end
  end
end

-------------------------
-- Norns UI
-------------------------
function key(n,z)
  if n==2 and z==1 then
    randomize_all_grains()
  end
end

function enc(n,d)
  -- no custom enc behavior
end

-------------------------
-- DRAW
-------------------------
local ui_metro
function redraw()
  screen.clear()
  for i = 1, NUM_VOICES do
    local pos = positions[i]
    if voices[i].active then
      screen.level(15)            -- Bright fill for active voice
      screen.rect(pos.x, pos.y, SQUARE_SIZE, SQUARE_SIZE)
      screen.fill()
    else
      screen.level(5)             -- Dim outline for inactive voice
      screen.rect(pos.x, pos.y, SQUARE_SIZE, SQUARE_SIZE)
      screen.stroke()
    end
  end
  screen.update()
end

local function start_redraw_clock()
  ui_metro = metro.init()
  ui_metro.time = 1/15
  ui_metro.event = redraw
  ui_metro:start()
end

-------------------------
-- PARAMS
-------------------------
local function add_voice_params(i)
  params:add_separator("Voice "..i)

  params:add_file(i.."base_sample","Base Sample (V"..i..")","")
  params:set_action(i.."base_sample",function(file)
    if file~="" then
      engine.read(i,file)
    end
  end)

  params:add_option(i.."rnd_sample","Randomize Sample (V"..i..")",{"No","Yes"},1)
  params:add_option(i.."rate","Arp Rate (V"..i..")",RATE_OPTIONS,5)

  -- Lock Arpeggio
  params:add_option(i.."lock_arpeggio","Lock Arpeggio (V"..i..")",{"No","Yes"},1)

  params:add_number(i.."num_notes","Number of notes (V"..i..")",1,5,3)

--  params:add_control(i.."attack","Attack (ms) (V"..i..")",
--    controlspec.new(0,5000,"lin",1,10,"ms"))
--    params:add_control(i.."release","Release (ms) (V"..i..")",
--    controlspec.new(0,5000,"lin",1,1000,"ms"))

  params:add_option(i.."rnd_grains","Randomize grains (V"..i..")",{"No","Yes"},1)
  params:add_option(i.."rnd_velocity","Random velocity? (V"..i..")",{"No","Yes"},1)
  params:add_control(i.."min_rnd_vel","Min rnd vel (dB) (V"..i..")",
    controlspec.new(-60,0,"lin",0.1,-20,"dB"))
  params:add_control(i.."max_rnd_vel","Max rnd vel (dB) (V"..i..")",
    controlspec.new(-60,0,"lin",0.1,-6,"dB"))

  params:add_option(i.."arp_spread","Arp spread (V"..i..")",{"1","2","3"},1)

  params:add_control(i.."volume","Volume (dB) (V"..i..")",
    controlspec.new(-60,20,"lin",0.1,0,"dB"))

  params:add_number(i.."midi_channel","MIDI Channel (V"..i..")",1,16,i)
  params:add_number(i.."midi_note_min", "MIDI Note Min (V"..i..")", 0, 127, 0)
  params:add_number(i.."midi_note_max", "MIDI Note Max (V"..i..")", 0, 127, 127)

  params:add_control(i.."pan","Pan (V"..i..")",
    controlspec.new(-1,1,"lin",0.01,0,""))
  params:set_action(i.."pan",function(val)
    engine.pan(i,val)
  end)

  -- granular engine
  params:add_control(i.."size","Grain size (ms) (V"..i..")",
    controlspec.new(1,500,"lin",1,100,"ms"))
  params:set_action(i.."size",function(val)
    engine.size(i,val/1000)
  end)

  params:add_control(i.."density","Grain density (hz) (V"..i..")",
    controlspec.new(0,512,"lin",0.01,20,"hz"))
  params:set_action(i.."density",function(val)
    engine.density(i,val)
  end)

  params:add_control(i.."spread","Grain spread (%) (V"..i..")",
    controlspec.new(0,100,"lin",1,0,"%"))
  params:set_action(i.."spread",function(val)
    engine.spread(i,val/100)
  end)

  params:add_control(i.."jitter","Grain jitter (ms) (V"..i..")",
    controlspec.new(0,2000,"lin",1,0,"ms"))
  params:set_action(i.."jitter",function(val)
    engine.jitter(i,val/1000)
  end)

  -- random seek
  params:add_option(i.."rnd_seek","Randomize seek (V"..i..")",{"No","Yes"},1)
  params:set_action(i.."rnd_seek",function()
    update_random_seek(i)
  end)

  params:add_control(i.."rnd_seek_min","Rnd seek min (V"..i..")",
    controlspec.new(1,5000,"lin",1,500,"ms"))
  params:set_action(i.."rnd_seek_min",function()
    update_random_seek(i)
  end)

  params:add_control(i.."rnd_seek_max","Rnd seek max (V"..i..")",
    controlspec.new(1,5000,"lin",1,1500,"ms"))
  params:set_action(i.."rnd_seek_max",function()
    update_random_seek(i)
  end)
end

function init_params()
  params:add_separator("Global")

  params:add_file("sample_dir","Sample Directory",_path.audio)
  params:set_action("sample_dir",function(file)
    if file~="" then
      local folder= file_dir_name(file)
      sample_dir= folder
      print("sample_dir => "..sample_dir)
    end
  end)

  params:add_option("scale","Scale",SCALE_NAMES,1)
  params:add_option("key","Key",NOTE_NAMES,1)

  params:add_control("morph_time","Morph time (ms)",
    controlspec.new(0,2000,"lin",10,500,"ms"))

  params:add{
    type="number", id="midi_device", name="MIDI Device",
    min=1,max=16,default=1,
    action=function(value)
      midi_in= midi.connect(value)
      midi_in.event= midi_event
    end
  }

  params:add_separator("Random Grain Bounds")
  params:add_control("grain_min_size","Size min",
    controlspec.new(1,500,"lin",1,20,"ms"))
  params:add_control("grain_max_size","Size max",
    controlspec.new(1,500,"lin",1,200,"ms"))
  params:add_control("grain_min_density","Density min",
    controlspec.new(0,512,"lin",0.01,1,"hz"))
  params:add_control("grain_max_density","Density max",
    controlspec.new(0,512,"lin",0.01,40,"hz"))
  params:add_control("grain_min_spread","Spread min",
    controlspec.new(0,100,"lin",1,0,"%"))
  params:add_control("grain_max_spread","Spread max",
    controlspec.new(0,100,"lin",1,100,"%"))
  params:add_control("grain_min_jitter","Jitter min",
    controlspec.new(0,2000,"lin",1,0,"ms"))
  params:add_control("grain_max_jitter","Jitter max",
    controlspec.new(0,2000,"lin",1,500,"ms"))

  for i=1, NUM_VOICES do
    add_voice_params(i)
  end

  params:add_separator("Reverb")
  params:add_control("reverb_mix","Reverb mix (%)",
    controlspec.new(0,100,"lin",1,50,"%"))
  params:set_action("reverb_mix",function(x)
    engine.reverb_mix(x/100)
  end)

  params:add_control("reverb_room","Reverb room (%)",
    controlspec.new(0,100,"lin",1,50,"%"))
  params:set_action("reverb_room",function(x)
    engine.reverb_room(x/100)
  end)

  params:add_control("reverb_damp","Reverb damp (%)",
    controlspec.new(0,100,"lin",1,50,"%"))
  params:set_action("reverb_damp",function(x)
    engine.reverb_damp(x/100)
  end)

  params:default()
  params:bang()
end

function init()
  math.randomseed(os.time())
  init_params()

  for i=1, NUM_VOICES do
    engine.gate(i,0)
    random_seek_metros[i]= nil
  end

  midi_in= midi.connect(params:get("midi_device"))
  midi_in.event= midi_event

  start_redraw_clock()
  redraw() 
end
