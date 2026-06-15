ISYM      := /I
CSYM      := /c
CXX       := cl
CXX_FLAGS := /EHsc /await:strict /std:c++20 /Zi /MD /Zc:preprocessor
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

INCLCUDES := ${ISYM}${UTILS} ${ISYM}${UTILS}/ap ${ISYM}${UTILS}/co ${ISYM}${UTILS}/generic ${ISYM}.
INCLCUDES += ${ISYM}${IMGUI} ${ISYM}${IMGUI}/backends/ ${ISYM}${IMPLOT}

# This is a header-only project 
DEPS      := $(wildcard ./*.h)
SRCS      += ${IMGUI_SRC} ${BACKEND_SRC} ${IMPLOT_SRC}
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
