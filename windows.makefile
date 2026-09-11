ISYM      := /I
CSYM      := /c
CXX       := cl
# /O2 (maximize speed). Without an explicit /O flag MSVC compiles at /Od - optimisations OFF - so
# everything here, ImGui and virt_composer included, was being built unoptimised. Measured 2026-09-05
# on the Lua<->C++ boundary microbenchmark: ~12% (a ref-argument call 60.85us -> 53.53us). Worth
# having, but noted honestly as a small win - the boundary marshalling itself dominates that number,
# not the code generation (see perf_composer.h and the 2026-09-05 measurements: 0.07us for a bare
# crossing against ~21us to return a struct and ~34us to pass a vc ref).
#
# MSVC has no /O3 - that is a GCC/Clang flag. If more is wanted here the next rungs are /Ob3
# (aggressive inlining) and /GL with /LTCG (whole-program), neither of which has been measured yet.
# /Zi stays: optimised builds keep their debug info, at the cost of inlined frames being less
# precise in a cpp_backtrace.h trace.
CXX_FLAGS := /EHs /await:strict /std:c++20 /Zi /MD /Zc:preprocessor /O2
CXX_FLAGS += /DVIRT_COMPOSER_ENABLE_LUA_IO=1

# ASAN=1 builds with the address sanitizer: `make clean && make ASAN=1`. OFF by default.
#
# WHAT IT BUYS over the page heap alternative, which is the other way to catch the same class:
# three stacks instead of one - where the bad access happened, where the block was FREED, and
# where it was allocated. A use-after-free is a question about the second of those, and a plain
# access-violation stack cannot answer it. It also needs no admin and no registry flag, unlike
# gflags page heap, which is a per-image setting under HKLM that outlives the run that set it.
#
# NEVER MEASURE WITH THIS ON. It puts a redzone around every allocation and poisons freed memory,
# so every number the /O2 comment above is about becomes meaningless. Same warning the page heap
# carries, and for the same reason.
#
# `make clean` FIRST, always: instrumented and uninstrumented objects must not be linked together,
# and a partial rebuild will happily do exactly that. /Zi is required and is already above; add
# /Od here too if an inlined frame reads wrong.
ifeq (${ASAN},1)
CXX_FLAGS += /fsanitize=address
endif
LIBS	  := /link gdi32.lib glfw3.lib opengl32.lib

IMGUI     := ../imgui/
IMPLOT    := ../implot/
UTILS     := ../utils/

IMGUI_SRC := ${IMGUI}/imgui.cpp
IMGUI_SRC += ${IMGUI}/imgui_draw.cpp
IMGUI_SRC += ${IMGUI}/imgui_tables.cpp
IMGUI_SRC += ${IMGUI}/imgui_widgets.cpp
IMGUI_SRC += ${IMGUI}/imgui_demo.cpp

IMPLOT_SRC := ${IMPLOT}/implot.cpp
IMPLOT_SRC += ${IMPLOT}/implot_demo.cpp
IMPLOT_SRC += ${IMPLOT}/implot_items.cpp

BACKEND_SRC := ${IMGUI}/backends/imgui_impl_glfw.cpp
BACKEND_SRC += ${IMGUI}/backends/imgui_impl_opengl3.cpp

INCLCUDES := /I${UTILS} /I${UTILS}/ap /I${UTILS}/co /I${UTILS}/generic /I.
INCLCUDES += /I${IMGUI} /I${IMGUI}/backends/ /I${IMPLOT}

# This is a header-only project 
DEPS      := $(wildcard ./*.h)
SRCS      += ${IMGUI_SRC} ${BACKEND_SRC} ${IMPLOT_SRC}
SRCS      += ${UTILS}/virt_composer.cpp
SRCS      += debug_input_pipe.cpp
OBJS      := $(SRCS:.cpp=.obj)

all: ${OBJS} $(DEPS)
	${CXX} ${CXX_FLAGS} ${INCLCUDES} main.cpp  $(notdir ${OBJS}) ${LIBS}

${OBJS}:$(notdir %.obj):%.cpp
	${CXX} /c ${CXX_FLAGS} ${INCLCUDES} $< /link /OUT $(notdir $@)

clean:
	rm -f *.obj
	rm -f *.exe
	rm -f *.ilk
	rm -f *.pdb

push:
	-git add *
	git commit -m "wip"
	git push
