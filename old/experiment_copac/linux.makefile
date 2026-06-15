CXX       := g++-13
CXX_FLAGS := -std=c++2a -g -export-dynamic -Wno-format-security
LIBS      := -lpthread -ldl -lbacktrace

UTILS     := ../../utils/

INCLCUDES := -I${UTILS} -I${UTILS}/ap -I${UTILS}/co -I${UTILS}/generic -I.

# This is a header-only project 
DEPS      := $(wildcard ./*.h)
SRCS      += ${UTILS}/virt_composer.cpp
OBJS      := $(SRCS:.cpp=.o)

all: ${OBJS} $(DEPS)
	${CXX} ${CXX_FLAGS} ${INCLCUDES} main.cpp ${OBJS} ${LIBS}

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
