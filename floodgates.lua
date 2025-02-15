-- FLOODGATES 
-- 7-voice Granular Arppegiated Synth
-- by @nzimas

engine.name = "Glut"
local MusicUtil = require "musicutil"

-------------------------
-- GLOBAL
-------------------------
local NUM_VOICES   = 7
local SQUARE_SIZE  = 20

-- We store separate metros for random-seek logic
local random_seek_metros = {}

-- For drawing 7 squares: 4 top, 3 bottom
local positions = {
  {x=10,  y=10},  -- voice 1
  {x=40,  y=10},  -- voice 2
  {x=70,  y=10},  -- voice 3
  {x=100, y=10},  -- voice 4
  {x=25,  y=40},  -- voice 5
  {x=55,  y=40},  -- voice 6
  {x=85,  y=40},  -- voice 7
}

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

-------------------------
-- VOICES
-------------------------
local voices = {}
for i=1, NUM_VOICES do
  voices[i] = {
    active      = false,
    midi_note   = nil,
    arp_clock   = nil,
    notes_held  = {},
    chord_tones = {},
  }
end

-------------------------
-- RANDOM HELPERS
-------------------------
local function random_float(low, high)
  return low + math.random()*(high - low)
end
local function random_int(low, high)
  return math.floor(random_float(low, high+1))
end

-------------------------
-- get_random_sample()?
-------------------------
-- If you want random sample from a folder, define the logic here.
local function get_random_sample()
  return ""
end

-------------------------
-- BUILD SCALE / CHORD
-------------------------
local function build_scale_notes()
  local root_index = params:get("key") - 1
  local root_midi  = 60 + root_index
  local scale_name = SCALE_NAMES[ params:get("scale") ]
  local intervals  = SCALE_INTERVALS[scale_name]
  local notes = {}
  for octave=-1,6 do
    local base = root_midi + 12*octave
    for _, iv in ipairs(intervals) do
      table.insert(notes, base + iv)
    end
  end
  table.sort(notes)
  return notes
end

local function generate_chord(voice_idx, triggered_note)
  local num_notes = params:get(voice_idx.."num_notes")
  local spread    = params:get(voice_idx.."arp_spread")
  local scale_notes = build_scale_notes()
  local chord_tones = { triggered_note }

  local valid_tones = {}
  for _,n in ipairs(scale_notes) do
    local diff = n - triggered_note
    if diff >= -(spread*12) and diff <= (spread*12) then
      table.insert(valid_tones, n)
    end
  end
  table.sort(valid_tones)

  local pruned = {}
  for _,v in ipairs(valid_tones) do
    if v ~= triggered_note then table.insert(pruned,v) end
  end
  for _=1,(num_notes-1) do
    if #pruned<1 then break end
    local idx = random_int(1,#pruned)
    table.insert(chord_tones, pruned[idx])
    table.remove(pruned, idx)
  end
  table.sort(chord_tones)
  return chord_tones
end

-------------------------
-- GRAIN RANDOM
-------------------------
local function smooth_transition(param_name, new_val, duration)
  clock.run(function()
    local start_val = params:get(param_name)
    local steps = 20
    local dt = duration / steps
    for s=1, steps do
      local t = s/steps
      params:set(param_name, start_val + (new_val - start_val)*t)
      clock.sleep(dt)
    end
    params:set(param_name, new_val)
  end)
end

local function randomize_voice_grains(i)
  local morph = params:get("morph_time") / 1000.0
  local size    = random_float(params:get("grain_min_size"),    params:get("grain_max_size"))
  local density = random_float(params:get("grain_min_density"), params:get("grain_max_density"))
  local spread  = random_float(params:get("grain_min_spread"),  params:get("grain_max_spread"))
  local jitter  = random_float(params:get("grain_min_jitter"),  params:get("grain_max_jitter"))

  smooth_transition(i.."size",    size,    morph)
  smooth_transition(i.."density", density, morph)
  smooth_transition(i.."spread",  spread,  morph)
  smooth_transition(i.."jitter",  jitter,  morph)
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
  local pos = math.random()  -- 0..1
  engine.seek(voice_idx, pos)
  local tmin = params:get(voice_idx.."rnd_seek_min")
  local tmax = params:get(voice_idx.."rnd_seek_max")
  if tmax < tmin then
    local tmp = tmin
    tmin = tmax
    tmax = tmp
  end
  local next_interval = math.random(tmin, tmax) / 1000.0
  random_seek_metros[voice_idx].time = next_interval
  random_seek_metros[voice_idx]:start()
end

local function update_random_seek(i)
  local val = params:get(i.."rnd_seek")
  if val==2 then
    -- yes => start
    if not random_seek_metros[i] then
      random_seek_metros[i] = metro.init()
      random_seek_metros[i].event = function()
        random_seek_tick(i)
      end
    end
    random_seek_tick(i)  -- immediate
  else
    -- no => stop
    if random_seek_metros[i] then
      random_seek_metros[i]:stop()
    end
  end
end

-------------------------
-- RATE / TIMING
-------------------------
local function fraction_to_beats(str)
  local num, den = string.match(str, "^(%d+)%/(%d+)$")
  if num and den then
    return tonumber(num)/tonumber(den)
  elseif str=="1" then
    return 1
  end
  return 1
end

local function generate_random_rhythm(chord_size, voice_idx)
  local rate_str = RATE_OPTIONS[ params:get(voice_idx.."rate") ]
  local base_beats = fraction_to_beats(rate_str)
  local durations = {}
  for i=1,chord_size do
    local factor = random_float(0.7,1.3)
    durations[i] = factor * base_beats
  end
  return durations
end

local function pick_random_direction()
  local r = random_int(1,4)
  if r==1 then return "up"
  elseif r==2 then return "down"
  elseif r==3 then return "pingpong"
  else return "random"
  end
end

-------------------------
-- ARPEGGIO
-------------------------
local function run_arpeggio(voice_idx)
  local chord   = voices[voice_idx].chord_tones
  local csize   = #chord
  local dirMode = pick_random_direction()
  local durations = generate_random_rhythm(csize, voice_idx)
  local i   = 1
  local d   = 1

  engine.gate(voice_idx, 1)  -- no mid-note gating

  while voices[voice_idx].active do
    local note
    if dirMode=="random" then
      note = chord[random_int(1,csize)]
    else
      note = chord[i]
    end

    if params:get(voice_idx.."rnd_grains")==2 then
      randomize_voice_grains(voice_idx)
    end

    if params:get(voice_idx.."rnd_velocity")==2 then
      local vmin = params:get(voice_idx.."min_rnd_vel")
      local vmax = params:get(voice_idx.."max_rnd_vel")
      local rv   = random_float(vmin,vmax)
      engine.volume(voice_idx, math.pow(10,rv/20))
    else
      local vol_db = params:get(voice_idx.."volume")
      engine.volume(voice_idx, math.pow(10,vol_db/20))
    end

    -- Pitch
    local ratio = math.pow(2,(note-60)/12)
    engine.pitch(voice_idx, ratio)

    -- Wait
    clock.sleep(durations[i] * clock.get_beat_sec())

    -- direction stepping
    if dirMode=="up" then
      i = i+1
      if i>csize then i=1 end
    elseif dirMode=="down" then
      i = i-1
      if i<1 then i=csize end
    elseif dirMode=="pingpong" then
      i = i+d
      if i>csize then
        i = csize-1
        d = -1
      elseif i<1 then
        i = 2
        d = 1
      end
    end
  end

  engine.gate(voice_idx, 0)
end

-------------------------
-- MIDI
-------------------------
local midi_in

local function midi_event(data)
  local msg = midi.to_msg(data)
  if msg.type=="note_on" then
    if msg.vel>0 then
      for i=1, NUM_VOICES do
        if params:get(i.."midi_channel")== msg.ch then
          if voices[i].arp_clock then
            clock.cancel(voices[i].arp_clock)
            voices[i].arp_clock=nil
          end
          voices[i].active = true
          voices[i].midi_note = msg.note
          voices[i].notes_held[msg.note] = true
          local chord = generate_chord(i,msg.note)
          voices[i].chord_tones = chord

          -- load sample once
          if params:get(i.."rnd_sample")==2 then
            local path = get_random_sample()
            if path~="" then
              engine.read(i, path)
            end
          else
            local base_file = params:get(i.."base_sample")
            if base_file~="" then
              engine.read(i, base_file)
            end
          end

          voices[i].arp_clock = clock.run(function()
            run_arpeggio(i)
          end)
        end
      end
    else
      -- velocity=0 => note_off
      for i=1, NUM_VOICES do
        if params:get(i.."midi_channel")== msg.ch then
          voices[i].notes_held[msg.note] = nil
          local count=0
          for _,v in pairs(voices[i].notes_held) do
            if v then count=count+1 end
          end
          if count==0 then
            voices[i].active=false
          end
        end
      end
    end
  elseif msg.type=="note_off" then
    for i=1, NUM_VOICES do
      if params:get(i.."midi_channel")== msg.ch then
        voices[i].notes_held[msg.note] = nil
        local count=0
        for _,v in pairs(voices[i].notes_held) do
          if v then count=count+1 end
        end
        if count==0 then
          voices[i].active=false
        end
      end
    end
  end
end

-------------------------
-- Norns Keys/Enc
-------------------------
function key(n,z)
  if n==2 and z==1 then
    randomize_all_grains()
  end
end
function enc(n,d)
  -- none
end

-------------------------
-- DRAW
-------------------------
local ui_metro
function redraw()
  screen.clear()
  for i=1, NUM_VOICES do
    local pos = positions[i]
    screen.level(15)
    screen.rect(pos.x,pos.y,SQUARE_SIZE,SQUARE_SIZE)
    screen.stroke()
    if voices[i].active then
      screen.level(10)
      screen.rect(pos.x,pos.y,SQUARE_SIZE,SQUARE_SIZE)
      screen.fill()
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
    if file~="" then engine.read(i,file) end
  end)

  params:add_option(i.."rnd_sample","Randomize Sample (V"..i..")",{"No","Yes"},1)
  params:add_option(i.."rate","Rate (V"..i..")",RATE_OPTIONS,5)
  params:add_number(i.."num_notes","Number of notes (V"..i..")",1,5,3)

  params:add_control(i.."attack","Attack (ms) (V"..i..")",
    controlspec.new(0,5000,"lin",1,10,"ms"))
  params:add_control(i.."release","Release (ms) (V"..i..")",
    controlspec.new(0,5000,"lin",1,1000,"ms"))

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

  -------------------------
  -- PAN Parameter
  -------------------------
  -- Range from -1.0 (left) to +1.0 (right), default=0.0
  params:add_control(i.."pan","Pan (V"..i..")",
    controlspec.new(-1, 1, "lin", 0.01, 0, ""))
  params:set_action(i.."pan",function(val)
    engine.pan(i, val)
  end)

  -- Granular controls
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

  -- Random Seek
  params:add_option(i.."rnd_seek","Randomize seek (V"..i..")",{"No","Yes"},1)
  params:set_action(i.."rnd_seek",function() update_random_seek(i) end)

  params:add_control(i.."rnd_seek_min","Rnd seek min (ms) (V"..i..")",
    controlspec.new(1,5000,"lin",1,500,"ms"))
  params:set_action(i.."rnd_seek_min",function() update_random_seek(i) end)

  params:add_control(i.."rnd_seek_max","Rnd seek max (ms) (V"..i..")",
    controlspec.new(1,5000,"lin",1,1500,"ms"))
  params:set_action(i.."rnd_seek_max",function() update_random_seek(i) end)
end

function init_params()
  params:add_separator("Global")

  params:add_text("sample_dir","Sample directory","/home/we/dust/audio")
  params:add_option("scale","Scale",SCALE_NAMES,1)
  params:add_option("key","Key",NOTE_NAMES,1)
  
  params:add_control("morph_time","Morph time (ms)",
    controlspec.new(0,2000,"lin",10,500,"ms"))

  params:add{
    type="number",id="midi_device",name="MIDI Device",
    min=1,max=16,default=1,
    action=function(value)
      midi_in = midi.connect(value)
      midi_in.event = midi_event
    end
  }

  params:add_separator("Random Grain Bounds")
  params:add_control("grain_min_size","Grain size min (ms)",
    controlspec.new(1,500,"lin",1,20,"ms"))
  params:add_control("grain_max_size","Grain size max (ms)",
    controlspec.new(1,500,"lin",1,200,"ms"))
  params:add_control("grain_min_density","Grain density min (hz)",
    controlspec.new(0,512,"lin",0.01,1,"hz"))
  params:add_control("grain_max_density","Grain density max (hz)",
    controlspec.new(0,512,"lin",0.01,40,"hz"))
  params:add_control("grain_min_spread","Grain spread min (%)",
    controlspec.new(0,100,"lin",1,0,"%"))
  params:add_control("grain_max_spread","Grain spread max (%)",
    controlspec.new(0,100,"lin",1,100,"%"))
  params:add_control("grain_min_jitter","Grain jitter min (ms)",
    controlspec.new(0,2000,"lin",1,0,"ms"))
  params:add_control("grain_max_jitter","Grain jitter max (ms)",
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

-------------------------
-- INIT
-------------------------
function init()
  math.randomseed(os.time())

  init_params()
  for i=1, NUM_VOICES do
    random_seek_metros[i] = nil
    engine.gate(i,0)
  end

  midi_in = midi.connect(params:get("midi_device"))
  midi_in.event = midi_event

  start_redraw_clock()
end
