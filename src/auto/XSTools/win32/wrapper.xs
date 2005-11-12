#include <stdio.h>
#include <stdlib.h>
#include <windows.h>
#include <Tlhelp32.h>
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

DWORD GetProcByName (char * name);
int InjectDLL(DWORD ProcID, LPCTSTR dll);


MODULE = WinUtils		PACKAGE = WinUtils		PREFIX = WinUtils_
PROTOTYPES: ENABLE


unsigned long
GetProcByName(name)
		char *name
	CODE:
		RETVAL = (unsigned long) GetProcByName(name);
	OUTPUT:
		RETVAL

int
InjectDLL(ProcID, dll)
		unsigned long ProcID
		char *dll
	CODE:
		RETVAL = InjectDLL((DWORD) ProcID, dll);
	OUTPUT:
		RETVAL

int
ShellExecute(handle, operation, file)
		unsigned int handle
		SV *operation
		char *file
	INIT:
		char *op = NULL;
	CODE:
		if (operation && SvOK (operation))
			op = SvPV_nolen (operation);
		RETVAL = ((int) ShellExecute((HWND) handle, op, file, NULL, NULL, SW_NORMAL)) == 42;
	OUTPUT:
		RETVAL

void
listProcesses()
	INIT:
		HANDLE toolhelp;
		PROCESSENTRY32 pe;
	PPCODE:
		pe.dwSize = sizeof(PROCESSENTRY32);
		toolhelp = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
		if (Process32First(toolhelp, &pe)) {
			do {
				HV *hash;

				hash = (HV *) sv_2mortal ((SV *) newHV ());
				hv_store (hash, "exe", 3,
					newSVpv (pe.szExeFile, 0),
					0);
				hv_store (hash, "pid", 3,
					newSVuv (pe.th32ProcessID),
					0);
				XPUSHs (newRV ((SV *) hash));
			} while (Process32Next(toolhelp,&pe));
		}
		CloseHandle(toolhelp);

void
playSound(file)
	char *file
CODE:
	sndPlaySound(NULL, SND_ASYNC);
	sndPlaySound(file, SND_ASYNC | SND_NODEFAULT);

void
FlashWindow(handle)
	IV handle
CODE:
	if (GetActiveWindow() != (HWND) handle)
		FlashWindow((HWND) handle, TRUE);

unsigned long
OpenProcess(Access, ProcID)
		unsigned long Access
		unsigned long ProcID
	CODE:
		RETVAL = ((DWORD) OpenProcess((DWORD)Access, 0, (DWORD)ProcID));
	OUTPUT:
		RETVAL

unsigned long
SystemInfo_PageSize()
	INIT:
		SYSTEM_INFO si;
	CODE:
		GetSystemInfo((LPSYSTEM_INFO)&si);
		RETVAL = si.dwPageSize;
	OUTPUT:
		RETVAL

unsigned long
SystemInfo_MinAppAddress()
	INIT:
		SYSTEM_INFO si;
	CODE:
		GetSystemInfo((LPSYSTEM_INFO)&si);
		RETVAL = ((DWORD) si.lpMinimumApplicationAddress);
	OUTPUT:
		RETVAL

unsigned long
SystemInfo_MaxAppAddress()
	INIT:
		SYSTEM_INFO si;
	CODE:
		GetSystemInfo((LPSYSTEM_INFO)&si);
		RETVAL = ((DWORD) si.lpMaximumApplicationAddress);
	OUTPUT:
		RETVAL

unsigned long
VirtualProtectEx(ProcHND, lpAddr, dwSize, dwProtection)
		unsigned long ProcHND
		unsigned long lpAddr
		unsigned long dwSize
		unsigned long dwProtection
	INIT:
		DWORD old;
	CODE:
		if (0 == VirtualProtectEx((HANDLE)ProcHND, (LPVOID)lpAddr, (SIZE_T)dwSize, (DWORD)dwProtection, (PDWORD)&old)) {
			RETVAL = 0;
		} else {
			RETVAL = old;
		}
	OUTPUT:
		RETVAL

SV *
ReadProcessMemory(ProcHND, lpAddr, dwSize)
		unsigned long ProcHND
		unsigned long lpAddr
		unsigned long dwSize
	INIT:
		DWORD bytesRead;
		LPVOID buffer;
	CODE:
		buffer = malloc(dwSize);
		if (0 == ReadProcessMemory((HANDLE)ProcHND, (LPCVOID)lpAddr, buffer, (SIZE_T)dwSize, (SIZE_T*)&bytesRead)) {
			XSRETURN_UNDEF;
		} else {
			RETVAL = newSVpvn((char *)buffer, bytesRead);
		}
		free(buffer);
	OUTPUT:
		RETVAL

unsigned long
WriteProcessMemory(ProcHND, lpAddr, svData)
		unsigned long ProcHND
		unsigned long lpAddr
		SV *svData
	INIT:
		LPCVOID lpBuffer;
		int dwSize;
		DWORD bytesWritten;
	CODE:
		if (0 == SvPOK(svData)) {
			RETVAL = 0;
		} else {
			lpBuffer = (LPCVOID)SvPV(svData, dwSize);
			if (0 == WriteProcessMemory((HANDLE)ProcHND, (LPVOID)lpAddr, lpBuffer, (SIZE_T)dwSize, (SIZE_T*)&bytesWritten)) {
				RETVAL = 0;
			} else {
				RETVAL = bytesWritten;
			}
		}
	OUTPUT:
		RETVAL

void
CloseProcess(Handle)
		unsigned long Handle
	CODE:
		CloseHandle((HANDLE)Handle);

