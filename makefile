NAME      := a.out

IMGUI     := ./imgui/
IMPLOT    := ./implot/

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


UTILS     := ./utils/
INCLCUDES := -I${UTILS} -I${UTILS}/ap -I${UTILS}/co -I${UTILS}/generic -I.
INCLCUDES += -I${IMGUI} -I${IMGUI}/backends/ -I${IMPLOT}
LIBS      := -lpthread -ldl -lglfw -lcurl
LIBS      += -lglfw -lGL

SRCS      := $(wildcard ./*.cpp)
SRCS      += $(wildcard ${UTILS}/*.cpp)
SRCS      += ${IMGUI_SRC} ${BACKEND_SRC} ${IMPLOT_SRC}
OBJS      := $(SRCS:.cpp=.o)
DEPS      := $(SRCS:.cpp=.d)
CXX 	  := g++-11
CXX_FLAGS := -std=c++2a -g -export-dynamic
CXX_FLAGS += -Wno-format-security

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