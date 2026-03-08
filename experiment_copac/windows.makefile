CXX       := cl
CXX_FLAGS := /EHa /await:strict /std:c++20 /Zi /MD /Zc:preprocessor
CXX_FLAGS += /DVIRT_COMPOSER_ENABLE_LUA_IO=1
CXX_FLAGS += /DVIRT_COMPOSER_ENABLE_LUA_OS=1
LIBS	  := /link gdi32.lib glfw3.lib opengl32.lib
#if VIRT_COMPOSER_ENABLE_LUA_IO

UTILS     := ../../utils/

INCLCUDES := /I${UTILS} /I${UTILS}/ap /I${UTILS}/co /I${UTILS}/generic

# This is a header-only project 
SRCS :=
SRCS += ${UTILS}/virt_composer.cpp
DEPS := $(wildcard ./*.h)

all: $(DEPS)
	${CXX} ${CXX_FLAGS} ${INCLCUDES} main.cpp ${SRCS} ${LIBS}

clean:
	rm -f *.obj
	rm -f *.exe
	rm -f *.ilk
	rm -f *.pdb

push:
	-git add *
	git commit -m "wip"
	git push
