CXX       := g++-13
CXX_FLAGS := -std=c++2a -g -export-dynamic -Wno-format-security
LIBS      := -lpthread -ldl -lglfw -lcurl -lglfw -lGL

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

INCLCUDES := -I${UTILS} -I${UTILS}/ap -I${UTILS}/co -I${UTILS}/generic -I.
INCLCUDES += -I${IMGUI} -I${IMGUI}/backends/ -I${IMPLOT}

# This is a header-only project 
DEPS      := $(wildcard ./*.h)
SRCS      += ${IMGUI_SRC} ${BACKEND_SRC} ${IMPLOT_SRC}
OBJS      := $(SRCS:.cpp=.o)

all: ${OBJS} $(DEPS)
	${CXX} ${CXX_FLAGS} ${INCLCUDES} main.cpp  ${OBJS} ${LIBS}

${OBJS}:%.o:%.cpp
	${CXX} -c ${CXX_FLAGS} ${INCLCUDES} $< -o $@

clean:
	rm -f *.o
	rm -f *.obj
	rm -f *.exe
	rm -f *.ilk
	rm -f *.pdb

push:
	-git add *
	git commit -m "wip"
	git push
