"""The engine's function names, read from the player's own game.wasm.

wasm2c (run with --no-debug-names) calls every function w2c_game_fN, where N is its index in the
module (imports first). The browser build keeps a name section with the demangled C++ name of each
function, so the patchers can say which function they change and find it by that name instead of
by a bare number.

    python3 Scripts/engine_names.py --wasm path/to/game.wasm   writes Generated/funcnames.tsv
    from engine_names import fn                                 fn('rage::ioPad::Update(bool)') -> 10454

fn() fails loudly when a name is missing or not unique, so a different game build stops the
build at the patch that no longer fits instead of patching the wrong function.
"""
import argparse
from pathlib import Path

root = Path(__file__).resolve().parents[1]
TABLE = root / 'Generated/funcnames.tsv'
HEADER = root / 'Generated/engine-functions.h'
# Engine functions the host code calls directly (Source/*.c): each gets a macro in HEADER.
HOST_FUNCTIONS = {
    'PG_FN_PLAYER_ID': 'player_commands::CommandPlayerId()',
    'PG_FN_SET_PLAYER_INVINCIBLE': 'player_commands::CommandSetPlayerInvincible(int, bool)',
    'PG_FN_GET_PLAYER_INVINCIBLE': 'player_commands::CommandGetPlayerInvincible(int)',
    'PG_FN_CLEAR_WANTED': 'player_commands::CommandClearWantedLevel(int)',
    'PG_FN_GET_WANTED': 'player_commands::CommandGetPlayerWantedLevel(int)',
    'PG_FN_SET_MAX_WANTED': 'player_commands::CommandSetMaxWantedLevel(int)',
    'PG_FN_GET_MAX_WANTED': 'player_commands::CommandGetMaxWantedLevel()',
    'PG_FN_PED_VEHICLE': 'ped_commands::CommandGetVehiclePedIsIn(int, bool)',
    'PG_FN_REPAIR_VEHICLE': 'vehicle_commands::CommandSetVehicleFixed(int)',
    'PG_FN_VEHICLE_ENGINE_HEALTH': 'vehicle_commands::CommandSetVehicleEngineHealth(int, float)',
    'PG_FN_VEHICLE_DIRT': 'vehicle_commands::CommandSetVehicleDirtLevel(int, float)',
    'PG_FN_SET_CLOCK': 'clock_commands::CommandSetClockTime(int, int, int)',
    'PG_FN_SET_WEATHER': 'misc_commands::CommandSetWeatherTypeNowPersist(char const*)',
    'PG_FN_CLEAR_WEATHER': 'misc_commands::CommandClearWeatherTypePersist()',
    'PG_FN_CLEAR_WEATHER_OVERRIDE': 'misc_commands::CommandClearOverrideWeather()',

    'PG_FN_MODEL_INFO_AT_INDEX': 'CModelInfo::GetModelInfoFromLocalIndex(int)',
    'PG_FN_IS_VEHICLE_MODEL': 'streaming_commands::CommandIsThisModelAVehicle(int)',
    'PG_FN_RELEASE_MODEL': 'streaming_commands::CommandMarkModelAsNoLongerNeeded(int)',
    'PG_FN_GET_ENTITY_COORDS': 'entity_commands::CommandGetEntityCoords(int, bool)',
    'PG_FN_GET_ENTITY_HEADING': 'entity_commands::CommandGetEntityHeading(int)',
    'PG_FN_VEHICLE_CLASS': 'vehicle_commands::CommandGetVehicleClassFromName(int)',
    'PG_FN_VEHICLE_LABEL': 'vehicle_commands::CommandGetDisplayNameFromVehicleModel(int)',
    'PG_FN_VEHICLE_SEATS': 'vehicle_commands::CommandGetVehicleModelNumberOfSeats(int)',
    'PG_FN_GROUND_VEHICLE': 'vehicle_commands::CommandSetVehicleOnGroundProperly(int, float)',
    'PG_FN_ENTITY_EXISTS': 'entity_commands::CommandDoesEntityExist(int)',
    'PG_FN_ENTITY_OWNED': 'entity_commands::CommandDoesEntityBelongToThisScript(int, bool)',
    'PG_FN_DELETE_VEHICLE': 'vehicle_commands::CommandDeleteVehicle(int&)',
    'PG_FN_VEHICLE_OCCUPANT': 'vehicle_commands::CommandGetPedInVehicleSeat(int, int, bool)',
    'PG_FN_CURRENT_SCRIPT_HANDLER': 'CTheScripts::GetCurrentGtaScriptHandler()',
    'PG_FN_CREATE_VEHICLE': 'vehicle_commands::CommandCreateVehicle(int, rage::scrVector const&, float, bool, bool, bool)',
    'PG_FN_GET_CURRENT_PED_VEHICLE_WEAPON': 'weapon_commands::SetupScriptCommands()::scrWrapped_GET_CURRENT_PED_VEHICLE_WEAPON::Call(rage::scrThread::Info&)',
    'PG_FN_HASH_STRING_TRY_GET': 'rage::atHashStringNamespaceSupport::TryGetString(rage::atHashStringNamespaces, unsigned int)',
    'PG_FN_HAS_MODEL_LOADED': 'streaming_commands::HasModelLoaded(int)',
    'PG_FN_LOAD_SCENE_IS_LOADED': 'CLoadScene::IsLoaded()',
    'PG_FN_REQUEST_SCALEFORM_MOVIE': 'graphics_commands::CommandRequestScaleformMovieCommon(char const*, bool, bool)',
    'PG_FN_OPUS_DECODE_FRAME': 'opus_decode_frame',
    'PG_FN_LOAD_SCENE_START': 'CLoadScene::StartFromScript(rage::Vec3V const&, rage::Vec3V const&, float, rage::scrThreadId, bool, int)',
    'PG_FN_OPERATOR_NEW': 'operator new(unsigned long)',
    'PG_FN_PLAYER_PED_ID': 'player_commands::CommandPlayerPedId()',
    'PG_FN_PLAY_MOVIE': 'CMovieMgr::Play(unsigned int)',
    'PG_FN_PRELOAD_MOVIE': 'CMovieMgr::PreloadMovie(char const*, bool)',
    'PG_FN_PROFILE_SETTINGS_SET': 'CProfileSettings::Set(CProfileSettings::ProfileSettingId, int)',
    'PG_FN_REQUEST_MODEL': 'streaming_commands::CommandRequestModel(int)',
    'PG_FN_SBRK': 'sbrk',
    'PG_FN_SET_CURRENT_PED_VEHICLE_WEAPON': 'weapon_commands::SetupScriptCommands()::scrWrapped_SET_CURRENT_PED_VEHICLE_WEAPON::Call(rage::scrThread::Info&)',
    'PG_FN_SET_ENTITY_COORDS_NO_OFFSET': 'entity_commands::CommandSetEntityCoordsNoOffset(int, rage::scrVector const&, bool, bool, bool)',
    'PG_FN_SET_ENTITY_HEALTH': 'entity_commands::CommandSetEntityHealth(int, int, int)',
    'PG_FN_SET_MENU_PREFERENCE': 'CPauseMenu::SetMenuPreference(int, int)',
    'PG_FN_SET_PED_INTO_VEHICLE': 'ped_commands::CommandSetPedIntoVehicle(int, int, int)',
    'PG_FN_SET_TV_CHANNEL': 'graphics_commands::CommandSetTVChannel(int)',
    'PG_FN_DO_AUTO_SAVE': 'misc_commands::CommandDoAutoSave()',
    'PG_FN_GET_ENTITY_MODEL': 'entity_commands::CommandGetEntityModel(int)',
    'PG_FN_GET_ENTITY_SPEED': 'entity_commands::CommandGetEntitySpeed(int)',
    'PG_FN_GET_PED_DRAWABLE': 'ped_commands::CommandGetPedDrawableVariation(int, int)',
    'PG_FN_GET_PED_TEXTURE': 'ped_commands::CommandGetPedTextureVariation(int, int)',
    'PG_FN_GIVE_WEAPON': 'weapon_commands::CommandGiveWeaponToPed(int, int, int, bool, bool)',
    'PG_FN_WEAPON_ENTITY': 'weapon_commands::CommandGetCurrentPedWeaponEntityIndex(int, bool)',
    'PG_FN_SELECTED_WEAPON': 'weapon_commands::CommandGetSelectedPedWeapon(int)',
    'PG_FN_INSTRUCTIONAL_BUTTON': 'pad_commands::CommandGetInputInstructionalButtonsString(int, int, bool)',
    'PG_FN_BUDDY_GET_SIZE': 'rage::sysMemBuddyAllocator::GetSize(void const*) const',
    'PG_FN_REDUCE_PED_MODEL_BUDGET': 'CPopulationStreaming::SetReduceAmbientPedModelBudget(bool)',
    'PG_FN_REDUCE_VEHICLE_MODEL_BUDGET': 'CPopulationStreaming::SetReduceAmbientVehicleModelBudget(bool)',
    'PG_FN_PED_DENSITY_THIS_FRAME': 'ped_commands::CommandSetPedDensityMultiplierThisFrame(float)',
    'PG_FN_VEHICLE_DENSITY_THIS_FRAME': 'vehicle_commands::CommandSetVehicleDensityMultiplierThisFrame(float)',
    'PG_FN_PARKED_DENSITY_THIS_FRAME': 'vehicle_commands::CommandSetParkedVehicleDensityMultiplierThisFrame(float)',
    'PG_FN_LOD_SCALE_THIS_FRAME': 'streaming_commands::CommandOverrideLodScaleThisFrame(float)',
    'PG_FN_STAT_SET_INT': 'stats_commands::CommandStatSetInt(int, int, bool)',
    'PG_FN_STAT_GET_INT': 'stats_commands::CommandStatGetInt(int, int&, int)',
    'PG_FN_SYS_IPC_SLEEP': 'rage::sysIpcSleep(unsigned int)',
    'PG_FN_TV_SETUP_LESTER1': 'CTVPlaylistManager::SetupLester1CB()',
    'PG_FN_TV_SCALE_TO_REAL_TIME': 'CTVPlaylistManager::ScaleToRealTime(float)',
    'PG_FN_TV_CURRENT_SHOW_HASH': 'CTVPlaylistManager::GetCurrentShowNameHash()',
    'PG_FN_TV_SHOW_PLAY_TIME': 'audio_commands::SetupScriptCommands()::scrWrapped_GET_CURRENT_TV_SHOW_PLAY_TIME::Call(rage::scrThread::Info&)',
    'PG_FN_TV_SHOW_DURATION': 'audio_commands::SetupScriptCommands()::scrWrapped_GET_CURRENT_TV_SHOW_DURATION::Call(rage::scrThread::Info&)',
    'PG_FN_BEGIN_TAKE_HIGH_QUALITY_PHOTO': 'graphics_commands::CommandBeginTakeHighQualityPhoto()',
    'PG_FN_TAKE_HIGH_QUALITY_PHOTO_STATUS': 'graphics_commands::CommandGetStatusOfTakeHighQualityPhoto()',
    'PG_FN_BEGIN_LOW_QUALITY_PHOTO_COPY': 'graphics_commands::CommandBeginCreateLowQualityCopyOfPhoto(int)',
    'PG_FN_LOW_QUALITY_PHOTO_COPY_STATUS': 'graphics_commands::CommandGetStatusOfCreateLowQualityCopyOfPhoto(int)',
}


def _leb(data, pos):
    value = shift = 0
    while True:
        byte = data[pos]
        pos += 1
        value |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            return value, pos


def read_names(wasm):
    """Index -> name from the module's "name" custom section (function names subsection)."""
    data = Path(wasm).read_bytes()
    if data[:4] != b'\0asm':
        raise SystemExit(f'{wasm} is not a WebAssembly module')
    pos = 8
    while pos < len(data):
        section, pos = data[pos], pos + 1
        size, pos = _leb(data, pos)
        end = pos + size
        if section == 0:
            length, at = _leb(data, pos)
            if data[at:at + length] == b'name':
                at += length
                while at < end:
                    kind, at = data[at], at + 1
                    sub_size, at = _leb(data, at)
                    if kind == 1:
                        count, p = _leb(data, at)
                        names = {}
                        for _ in range(count):
                            index, p = _leb(data, p)
                            length, p = _leb(data, p)
                            names[index] = data[p:p + length].decode('utf-8', 'replace')
                            p += length
                        return names
                    at += sub_size
        pos = end
    raise SystemExit(f'{wasm} has no function names (name section); this game build is not supported')


def write(wasm):
    names = read_names(wasm)
    TABLE.parent.mkdir(exist_ok=True)
    with open(TABLE, 'w') as out:
        for index in sorted(names):
            out.write(f'{index}\t{" ".join(names[index].split())}\n')
    lines = ['// Generated by Scripts/engine_names.py from the game.wasm name section.', '#pragma once']
    for macro, name in HOST_FUNCTIONS.items():
        lines.append(f'#define {macro} w2c_game_f{fn(name)} // {name}')
    HEADER.write_text('\n'.join(lines) + '\n')
    print(f'engine_names: {len(names)} function names, {len(HOST_FUNCTIONS)} host calls')


_by_name = None


def fn(name):
    """The w2c_game_fN number of the engine function with this exact name."""
    global _by_name
    if _by_name is None:
        if not TABLE.exists():
            raise SystemExit(f'{TABLE} is missing: run Scripts/engine_names.py --wasm <game.wasm> (prepare.py does)')
        _by_name = {}
        for line in open(TABLE):
            index, _, label = line.rstrip('\n').partition('\t')
            _by_name.setdefault(label, []).append(int(index))
    found = _by_name.get(name, [])
    if len(found) != 1:
        raise SystemExit(f'engine function {name!r}: {"not found" if not found else "not unique"} in this game build')
    return found[0]


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--wasm', required=True)
    write(parser.parse_args().wasm)
