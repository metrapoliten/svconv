# Переключение режимов кнопкой в camera_lcd_top (Mega 138K Pro) на работающей камере: после каждого
# нажатия цепочка перезагружает ядра, и в кадровом буфере устанавливается кадр нового режима.
# Тот же верхний модуль, но кадр камеры 64×48 вместо 640×480 (обработка, переходы между доменами и
# управление те же; высота больше задержки цепочки — 9 строк), SCCB 400 кГц вместо 25 кГц и
# подавление дребезга кнопки 100 тактов (2 мкс) вместо 10 мс — иначе тест шёл бы часами. Полный
# кадр и экран проверяет tests/camera_lcd_top. Библиотека Gowin — см.
# tests/common/camera_lcd_top.mk. make test

ROOT := $(abspath ../..)

CAM_WIDTH       := 64
CAM_HEIGHT      := 48
BTN_STABLE_CLKS := 100
export CAM_WIDTH CAM_HEIGHT BTN_STABLE_CLKS

COCOTB_TEST_MODULES := test_camera_lcd_top_modes
COMPILE_ARGS += -Pcamera_lcd_top.CamWidth=$(CAM_WIDTH) -Pcamera_lcd_top.CamHeight=$(CAM_HEIGHT) \
                -Pcamera_lcd_top.SccbFreq=400000 -Pcamera_lcd_top.BtnStableClks=$(BTN_STABLE_CLKS)

include $(ROOT)/tests/common/camera_lcd_top.mk
