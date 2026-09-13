MODULE = Halogen
C_INCLUDES = -I.
SRC_FILES = *.cpp */*.cpp */*/*.cpp

CFLAGS += -std=c++20 -O3 -flto
DFLAGS += -DNDEBUG -DUSE_NEON -DUSE_POPCNT -DEVALFILE=\"verbatim.nn\"
WFLAGS += -Wfatal-errors -Wall -Wextra
LFLAGS += -flto -static-libstdc++

BENCH = bench >/dev/null

ifeq ($(ARCH),armv8)
	CFLAGS += -march=armv8-a
else ifeq ($(ARCH),armv8-dotprod)
	CFLAGS += -march=armv8.2-a+dotprod
	DFLAGS += -DUSE_NEON_DOTPROD
else ifeq ($(ARCH),native)
	CFLAGS += -march=native
else ifneq ($(filter $(COMP),gcc g++),)
	CFLAGS += -march=native
else
	CFLAGS += -march=armv8-a
endif

ifneq ($(filter $(COMP),gcc g++),)
	override COMP = g++
	CFLAGS += -flto-partition=one -fno-gcse
	DFLAGS += 
	WFLAGS += 
	LFLAGS += 
else
	override COMP = clang++
	CFLAGS += -funroll-loops --target=$(if $(filter $(ARCH),armv8-dotprod),aarch64-linux-android29,aarch64-linux-android24)
	DFLAGS += 
	WFLAGS += 
	LFLAGS += 
endif

build:
	$(COMP) $(CFLAGS) $(C_INCLUDES) $(DFLAGS) $(WFLAGS) $(SRC_FILES) $(LFLAGS) -o $(MODULE)
	strip $(MODULE)

profile-build:
ifneq ($(filter $(COMP),gcc g++),)
	$(COMP) $(CFLAGS) $(C_INCLUDES) -fprofile-generate $(DFLAGS) $(WFLAGS) $(SRC_FILES) $(LFLAGS) -lgcov -o $(MODULE)
	./$(MODULE) $(BENCH)
	$(COMP) $(CFLAGS) $(C_INCLUDES) -fprofile-use -fno-peel-loops -fno-tracer $(DFLAGS) $(WFLAGS) $(SRC_FILES) $(LFLAGS) -lgcov -o $(MODULE)
else
	$(COMP) $(CFLAGS) $(C_INCLUDES) -fprofile-instr-generate $(DFLAGS) $(WFLAGS) $(SRC_FILES) $(LFLAGS) -o $(MODULE)
	./$(MODULE) $(BENCH)
	llvm-profdata merge -output=default.profdata *.profraw
	$(COMP) $(CFLAGS) $(C_INCLUDES) -fprofile-instr-use $(DFLAGS) $(WFLAGS) $(SRC_FILES) $(LFLAGS) -o $(MODULE)
endif
	strip $(MODULE)

clean:
	@rm -f *.gcda *.profdata *.profraw $(MODULE)
