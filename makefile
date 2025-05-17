NAME      := a.out

ifeq ($(OS),Windows_NT)
	INCL_SYM  := -I
	CXX 	  := g++-11
	CXX_FLAGS := -std=c++2a -g -export-dynamic -Wno-format-security
else
	INCL_SYM  := -I
	CXX 	  := g++-13
	CXX_FLAGS := -std=c++2a -g -export-dynamic -Wno-format-security
endif

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
LIBS      := -lpthread -ldl -lglfw -lcurl
LIBS      += -lglfw -lGL

SRCS      := $(wildcard ./*.cpp)
SRCS      += $(wildcard ${UTILS}/*.cpp)
SRCS      += ${IMGUI_SRC} ${BACKEND_SRC} ${IMPLOT_SRC}
OBJS      := $(SRCS:.cpp=.o)
DEPS      := $(SRCS:.cpp=.d)

all: ${NAME}

${NAME}: ${DEPS} ${OBJS}
	${CXX} ${CXX_FLAGS} ${INCLCUDES} ${OBJS} ${LIBS} -o $@

${DEPS}: makefile
${OBJS}: makefile

${DEPS}:%.d:%.cpp
	${CXX} -c ${CXX_FLAGS} ${INCLCUDES} -MM $< -MF $@

include ${DEPS}

${OBJS}:%.o:%.cpp
	${CXX} -c ${CXX_FLAGS} ${INCLCUDES} $< -o $@

clean:
	rm -f ${OBJS}
	rm -f ${DEPS}
	rm -f ${NAME}

push:
	-git add *
	git commit -m "wip"
	git push
